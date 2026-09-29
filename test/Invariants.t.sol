// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Guilds} from "../src/Guilds.sol";
import {Realm} from "../src/Realm.sol";
import {Diplomacy} from "../src/Diplomacy.sol";
import {Season} from "../src/Season.sol";
import {Banners} from "../src/Banners.sol";

/// @dev Drives the whole game with five players and bounded inputs. Every action checks its own
///      preconditions so that a call never reverts for a reason the handler chose; the invariant
///      runner is configured to fail on any revert, so an unexpected revert is itself a finding.
///      Where an action is deliberately attempted without its preconditions (an unapproved
///      proposal, an early expiry, a second claim) the handler asserts that it reverts.
contract PactsHandler is Test {
    uint256 internal constant EPOCH = 1 hours;
    uint256 internal constant SEASON = 7 days;
    uint256 internal constant EPOCHS_PER_SEASON = SEASON / EPOCH;
    uint256 internal constant PRICE = 1e18;
    uint256 internal constant FEE_BPS = 500;
    uint256 internal constant MAX_GUILDS = 6;

    LaunchToken internal token;
    Guilds internal guilds;
    Realm internal realm;
    Diplomacy internal diplomacy;
    Season internal season;
    Banners internal banners;

    address[] public actors;

    // ------------------------------------------------------------ ghosts
    uint256 public ghostTroopsBought;
    uint256 public ghostTroopsLost; // measured only across settlements
    uint256 public ghostPaidIn; // tokens actors sent into the game
    uint256 public ghostPaidOut; // tokens the game sent to actors
    mapping(address actor => uint256) public ghostPaidOutTo;
    mapping(uint256 season => uint256) public ghostClaimed;
    mapping(uint256 pactId => Diplomacy.Status) public ghostTerminalStatus;
    uint256 public nextSeasonToClose;
    uint256 public ghostSettled; // settledEpochs as last observed by a settlement action
    mapping(string => uint256) public calls;
    uint256[] internal queuedAttacks;
    // Membership stints form an oracle independent of the proposal's join-sequence cutoff.
    mapping(uint256 proposal => mapping(address actor => uint256 stint)) internal queuedMemberStint;

    constructor(
        LaunchToken token_,
        Guilds guilds_,
        Realm realm_,
        Diplomacy diplomacy_,
        Season season_,
        Banners banners_,
        address[] memory actors_
    ) {
        token = token_;
        guilds = guilds_;
        realm = realm_;
        diplomacy = diplomacy_;
        season = season_;
        banners = banners_;
        actors = actors_;
    }

    // ----------------------------------------------------------- helpers

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _guild(uint256 seed) internal view returns (uint256) {
        uint256 n = guilds.guildCount();
        return n == 0 ? 0 : bound(seed, 1, n);
    }

    function _anyMemberOf(uint256 g) internal view returns (address) {
        for (uint256 i; i < actors.length; ++i) {
            if (guilds.guildOf(actors[i]) == g) return actors[i];
        }
        return address(0);
    }

    /// @dev Every other member votes; `voteSeed` decides each member's support so that proposals
    ///      are sometimes rejected. Returns whether the proposal ended up approved.
    function _voteAll(uint256 pid, uint256 g, address proposer, uint256 voteSeed) internal returns (bool) {
        for (uint256 i; i < actors.length; ++i) {
            address a = actors[i];
            if (a == proposer || guilds.guildOf(a) != g) continue;
            bool support = (voteSeed >> i) & 1 == 1 || voteSeed % 4 != 0; // mostly yes
            vm.prank(a);
            guilds.vote(pid, support);
        }
        return guilds.isApproved(pid);
    }

    function aliveTroops() public view returns (uint256 alive) {
        uint256 n = guilds.guildCount();
        for (uint256 g = 1; g <= n; ++g) {
            alive += realm.reserveOf(g);
        }
        (, uint256[144] memory garrisons) = realm.map();
        for (uint256 i; i < 144; ++i) {
            alive += garrisons[i];
        }
        // Troops committed to attacks in epochs that are not yet settled are in neither place.
        for (uint256 e = realm.settledEpochs(); e <= realm.currentEpoch(); ++e) {
            uint256[] memory tiles = realm.attackedTilesIn(e);
            for (uint256 t; t < tiles.length; ++t) {
                Realm.Attack[] memory list = realm.attacksOn(e, tiles[t]);
                for (uint256 i; i < list.length; ++i) {
                    alive += list[i].troops;
                }
            }
        }
    }

    function _alreadyAttacking(uint256 g, uint256 tile) internal view returns (bool) {
        Realm.Attack[] memory list = realm.attacksOn(realm.currentEpoch(), tile);
        for (uint256 i; i < list.length; ++i) {
            if (list[i].attacker == g) return true;
        }
        return false;
    }

    // -------------------------------------------------------- membership

    function found(uint256 actorSeed) external {
        calls["found"]++;
        address a = _actor(actorSeed);
        if (guilds.guildOf(a) != 0 || guilds.guildCount() >= MAX_GUILDS) return;
        uint256 before = guilds.guildCount();
        vm.prank(a);
        uint256 id = guilds.found("Guild");
        assertEq(id, before + 1, "guild ids are sequential");
        assertEq(guilds.guildOf(a), id);
        assertEq(guilds.memberCountOf(id), 1);
        assertEq(guilds.treasuryOf(id), 0, "a new guild starts with nothing");
    }

    function join(uint256 actorSeed, uint256 guildSeed) external {
        calls["join"]++;
        address a = _actor(actorSeed);
        uint256 g = _guild(guildSeed);
        if (g == 0 || guilds.guildOf(a) != 0) return;
        uint256 before = guilds.memberCountOf(g);
        vm.prank(a);
        guilds.join(g);
        assertEq(guilds.memberCountOf(g), before + 1);
        assertTrue(guilds.wasMemberAt(g, a, block.timestamp));
    }

    function leave(uint256 actorSeed) external {
        calls["leave"]++;
        address a = _actor(actorSeed);
        uint256 g = guilds.guildOf(a);
        if (g == 0) return;
        uint256 treasury = guilds.treasuryOf(g);
        uint256 balance = token.balanceOf(a);
        vm.prank(a);
        guilds.leave();
        assertEq(guilds.guildOf(a), 0);
        assertFalse(guilds.isMember(g, a));
        assertEq(guilds.treasuryOf(g), treasury, "leaving moves no treasury");
        assertEq(token.balanceOf(a), balance, "leaving pays nothing");
        assertFalse(guilds.wasMemberAt(g, a, block.timestamp));
    }

    function expel(uint256 actorSeed, uint256 targetSeed, uint256 voteSeed) external {
        calls["expel"]++;
        address a = _actor(actorSeed);
        address t = _actor(targetSeed);
        uint256 g = guilds.guildOf(a);
        if (g == 0 || t == a || guilds.guildOf(t) != g) return;
        vm.prank(a);
        uint256 pid = guilds.propose(Guilds.Kind.Expel, t, 0, 0, 0, 0);
        uint256 count = guilds.memberCountOf(g);
        if (_voteAll(pid, g, a, voteSeed)) {
            guilds.execute(pid);
            assertFalse(guilds.isMember(g, t));
            assertEq(guilds.guildOf(t), 0);
            assertEq(guilds.memberCountOf(g), count - 1);
            assertTrue(guilds.getProposal(pid).executed);
        } else {
            try guilds.execute(pid) {
                assertTrue(false, "unapproved expel executed");
            } catch {}
            assertTrue(guilds.isMember(g, t), "rejected expel changed membership");
        }
    }

    // ------------------------------------------------------------ troops

    function buyTroops(uint256 actorSeed, uint256 troopsSeed) external {
        calls["buyTroops"]++;
        address a = _actor(actorSeed);
        uint256 g = guilds.guildOf(a);
        if (g == 0) return;
        uint256 n = bound(troopsSeed, 1, 20);
        uint256 cost = n * PRICE;
        uint256 fee = cost * FEE_BPS / 10_000;
        uint256 reserve = realm.reserveOf(g);
        uint256 balance = token.balanceOf(a);
        uint256 realmBal = token.balanceOf(address(realm));
        uint256 seasonBal = token.balanceOf(address(season));
        uint256 alive = aliveTroops();
        vm.prank(a);
        uint256 paid = realm.buyTroops(n);
        assertEq(paid, cost);
        assertEq(token.balanceOf(a), balance - cost);
        assertEq(realm.reserveOf(g), reserve + n);
        assertEq(token.balanceOf(address(realm)), realmBal + cost - fee);
        assertEq(token.balanceOf(address(season)), seasonBal + fee);
        assertEq(aliveTroops(), alive + n, "buying creates exactly n troops");
        ghostTroopsBought += n;
        ghostPaidIn += cost;
    }

    function donate(uint256 actorSeed, uint256 guildSeed, uint256 amountSeed) external {
        calls["donate"]++;
        address a = _actor(actorSeed);
        uint256 g = _guild(guildSeed);
        if (g == 0) return;
        uint256 amount = bound(amountSeed, 1, 50e18);
        uint256 treasury = guilds.treasuryOf(g);
        vm.prank(a);
        guilds.deposit(g, amount);
        assertEq(guilds.treasuryOf(g), treasury + amount);
        ghostPaidIn += amount;
    }

    function treasuryTroops(uint256 actorSeed, uint256 troopsSeed, uint256 voteSeed) external {
        calls["treasuryTroops"]++;
        address a = _actor(actorSeed);
        uint256 g = guilds.guildOf(a);
        if (g == 0) return;
        uint256 treasury = guilds.treasuryOf(g);
        if (treasury < PRICE) return;
        uint256 maxTroops = treasury / PRICE;
        uint256 n = bound(troopsSeed, 1, maxTroops > 20 ? 20 : maxTroops);
        vm.prank(a);
        uint256 pid = guilds.propose(Guilds.Kind.TreasuryTroops, address(realm), n * PRICE, 0, 0, 0);
        uint256 reserve = realm.reserveOf(g);
        if (_voteAll(pid, g, a, voteSeed)) {
            uint256 got = realm.buyTroopsFromTreasury(pid);
            assertEq(got, n);
            assertEq(realm.reserveOf(g), reserve + n);
            assertEq(guilds.treasuryOf(g), treasury - n * PRICE);
            ghostTroopsBought += n;
        } else {
            try realm.buyTroopsFromTreasury(pid) {
                assertTrue(false, "unapproved treasury purchase went through");
            } catch {}
            assertEq(guilds.treasuryOf(g), treasury);
            assertEq(realm.reserveOf(g), reserve);
        }
    }

    function payout(uint256 actorSeed, uint256 recipientSeed, uint256 amountSeed, uint256 voteSeed) external {
        calls["payout"]++;
        address a = _actor(actorSeed);
        address to = _actor(recipientSeed);
        uint256 g = guilds.guildOf(a);
        if (g == 0) return;
        uint256 treasury = guilds.treasuryOf(g);
        if (treasury == 0) return;
        uint256 amount = bound(amountSeed, 1, treasury);
        vm.prank(a);
        uint256 pid = guilds.propose(Guilds.Kind.Payout, to, amount, 0, 0, 0);
        uint256 balance = token.balanceOf(to);
        if (_voteAll(pid, g, a, voteSeed)) {
            guilds.execute(pid);
            assertEq(token.balanceOf(to), balance + amount);
            assertEq(guilds.treasuryOf(g), treasury - amount);
            ghostPaidOut += amount;
            ghostPaidOutTo[to] += amount;
            try guilds.execute(pid) {
                assertTrue(false, "payout executed twice");
            } catch {}
        } else {
            try guilds.execute(pid) {
                assertTrue(false, "unapproved payout executed");
            } catch {}
            assertEq(token.balanceOf(to), balance);
            assertEq(guilds.treasuryOf(g), treasury);
        }
    }

    // ----------------------------------------------------------- attacks

    function attack(uint256 actorSeed, uint256 tileSeed, uint256 troopsSeed, uint256 voteSeed) external {
        calls["attack"]++;
        address a = _actor(actorSeed);
        uint256 g = guilds.guildOf(a);
        if (g == 0) return;
        uint256 reserve = realm.reserveOf(g);
        if (reserve == 0) return;
        // Mostly fight over a handful of tiles so attacks collide.
        uint256 tile = tileSeed % 5 == 0 ? bound(tileSeed, 0, 143) : bound(tileSeed, 0, 5);
        (uint256 holder,) = realm.tile(tile);
        if (holder == g || _alreadyAttacking(g, tile)) return;
        uint256 troops = bound(troopsSeed, 1, reserve);
        vm.prank(a);
        uint256 pid = guilds.propose(Guilds.Kind.Attack, address(realm), 0, tile, holder, troops);
        if (!_voteAll(pid, g, a, voteSeed)) {
            try realm.declareAttack(pid) {
                assertTrue(false, "unapproved attack declared");
            } catch {}
            assertEq(realm.reserveOf(g), reserve);
            return;
        }
        uint256 pactId = holder == 0 ? 0 : diplomacy.activePactBetween(g, holder);
        PactWatch memory w = _watchPact(pactId, g, holder);
        uint256 alive = aliveTroops();
        if (w.betrayal) {
            // This handler is in no guild: it must not be able to make the guild a betrayer.
            try realm.declareAttack(pid) {
                assertTrue(false, "a non-member declared a betrayal");
            } catch {}
            assertEq(realm.reserveOf(g), reserve);
            assertEq(uint256(diplomacy.getPact(pactId).status), uint256(Diplomacy.Status.Active));
        }
        vm.prank(a);
        uint256 epoch = realm.declareAttack(pid);
        assertEq(epoch, realm.currentEpoch());
        assertEq(realm.reserveOf(g), reserve - troops, "committed troops leave the reserve");
        assertEq(aliveTroops(), alive, "declaring an attack destroys no troops");
        if (holder != 0) assertTrue(realm.hasPendingAttack(g, holder));
        if (pactId != 0) _checkPactAfterAttack(pactId, g, holder, w);
    }

    /// @dev Keep proposals across handler calls so joins, departures, pacts and time can intervene.
    function queueAttack(uint256 actorSeed, uint256 tileSeed, uint256 troopsSeed, uint256 voteSeed) external {
        address a = _actor(actorSeed);
        uint256 g = guilds.guildOf(a);
        uint256 reserve = realm.reserveOf(g);
        if (g == 0 || reserve == 0) return;
        uint256 tile = bound(tileSeed, 0, 5);
        (uint256 holder,) = realm.tile(tile);
        if (holder == g) return;
        vm.prank(a);
        uint256 pid = guilds.propose(Guilds.Kind.Attack, address(realm), 0, tile, holder, bound(troopsSeed, 1, reserve));
        for (uint256 i; i < actors.length; ++i) {
            if (guilds.isMember(g, actors[i])) {
                queuedMemberStint[pid][actors[i]] = guilds.stintCount(g, actors[i]);
            }
        }
        _voteAll(pid, g, a, voteSeed);
        queuedAttacks.push(pid);
        calls["queuedAttackCreated"]++;
    }

    function declareQueuedAttack(uint256 proposalSeed, uint256 actorSeed) external {
        if (queuedAttacks.length == 0) return;
        uint256 pid = queuedAttacks[bound(proposalSeed, 0, queuedAttacks.length - 1)];
        Guilds.Proposal memory p = guilds.getProposal(pid);
        (uint256 holder,) = realm.tile(p.data1);
        uint256 reserve = realm.reserveOf(p.guildId);
        if (p.executed || holder != p.data2 || reserve < p.data3 || _alreadyAttacking(p.guildId, p.data1)) return;
        address a = _actor(actorSeed);
        uint256 pactId = diplomacy.activePactBetween(p.guildId, holder);
        PactWatch memory w = _watchPact(pactId, p.guildId, holder);
        uint256 stint = queuedMemberStint[pid][a];
        bool eligible = stint != 0 && guilds.isMember(p.guildId, a) && guilds.stintCount(p.guildId, a) == stint;
        bytes4 expectedError;
        if (w.betrayal && !eligible) expectedError = Realm.BetrayalRequiresMember.selector;
        else if (guilds.isExpired(pid)) expectedError = Guilds.ProposalExpired.selector;
        else if (!guilds.isApproved(pid)) expectedError = Guilds.ProposalNotApproved.selector;

        if (expectedError != bytes4(0)) {
            bytes32 beforeState = _queuedAttackState(pid, p);
            vm.expectRevert(expectedError);
            vm.prank(a);
            realm.declareAttack(pid);
            assertEq(_queuedAttackState(pid, p), beforeState, "rejected attack changed funds or game state");
            calls["queuedAttackRejected"]++;
            return;
        }
        uint256 alive = aliveTroops();
        vm.prank(a);
        uint256 epoch = realm.declareAttack(pid);
        assertEq(epoch, realm.currentEpoch());
        assertTrue(guilds.getProposal(pid).executed);
        assertEq(realm.reserveOf(p.guildId), reserve - p.data3);
        assertEq(aliveTroops(), alive, "declaring a queued attack destroys no troops");
        if (pactId != 0) _checkPactAfterAttack(pactId, p.guildId, holder, w);
        calls["queuedAttackDeclared"]++;
    }

    function _queuedAttackState(uint256 pid, Guilds.Proposal memory p) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                guilds.getProposal(pid),
                realm.reserveOf(p.guildId),
                realm.attacksOn(realm.currentEpoch(), p.data1),
                realm.hasPendingAttack(p.guildId, p.data2),
                diplomacy.activePactBetween(p.guildId, p.data2),
                diplomacy.betrayals(p.guildId, realm.seasonOfEpoch(realm.currentEpoch())),
                token.balanceOf(address(diplomacy)),
                token.balanceOf(address(guilds)),
                guilds.treasuryOf(p.guildId),
                guilds.treasuryOf(p.data2)
            )
        );
    }

    struct PactWatch {
        bool betrayal;
        uint256 bonds;
        uint256 victimTreasury;
        uint256 attackerTreasury;
    }

    function _watchPact(uint256 pactId, uint256 attacker, uint256 victim) internal view returns (PactWatch memory w) {
        uint256 epoch = realm.currentEpoch();
        if (pactId != 0) {
            Diplomacy.Pact memory p = diplomacy.getPact(pactId);
            w.betrayal = epoch <= p.endEpoch;
            w.bonds = p.bondA + p.bondB;
            w.victimTreasury = guilds.treasuryOf(victim);
            w.attackerTreasury = guilds.treasuryOf(attacker);
        }
        assertEq(diplomacy.wouldBreakPact(attacker, victim, epoch), w.betrayal, "wouldBreakPact disagrees");
    }

    function _checkPactAfterAttack(uint256 pactId, uint256 attacker, uint256 victim, PactWatch memory w) internal {
        Diplomacy.Pact memory after_ = diplomacy.getPact(pactId);
        assertEq(diplomacy.activePactBetween(attacker, victim), 0, "an attacked pact is no longer active");
        if (w.betrayal) {
            assertEq(uint256(after_.status), uint256(Diplomacy.Status.Broken));
            assertEq(guilds.treasuryOf(victim), w.victimTreasury + w.bonds, "victim receives both bonds");
            assertEq(guilds.treasuryOf(attacker), w.attackerTreasury, "betrayer gets nothing back");
            ghostTerminalStatus[pactId] = Diplomacy.Status.Broken;
        } else {
            assertEq(uint256(after_.status), uint256(Diplomacy.Status.Expired));
            ghostTerminalStatus[pactId] = Diplomacy.Status.Expired;
        }
    }

    /// @dev Settles up to `max` ended epochs one at a time with `settle()`, checking each epoch's
    ///      tile outcomes against what was declared.
    function settle(uint256 maxSeed) external {
        calls["settle"]++;
        uint256 current = realm.currentEpoch();
        uint256 settled = realm.settledEpochs();
        if (current <= settled) {
            try realm.settle() {
                assertTrue(false, "settled an epoch that has not ended");
            } catch {}
            try realm.settleStep(1) {
                assertTrue(false, "stepped an epoch that has not ended");
            } catch {}
            return;
        }
        uint256 max = bound(maxSeed, 1, 4);
        uint256 alive = aliveTroops();
        uint256 realmBal = token.balanceOf(address(realm));
        for (uint256 i; i < max && realm.currentEpoch() > realm.settledEpochs(); ++i) {
            _settleOneEpoch(false, 0, 0);
        }
        uint256 aliveAfter = aliveTroops();
        assertLe(aliveAfter, alive, "settlement never creates troops");
        ghostTroopsLost += alive - aliveAfter;
        assertEq(token.balanceOf(address(realm)), realmBal, "settlement moves no tokens");
        ghostSettled = realm.settledEpochs();
    }

    /// @dev Settles every ended epoch in one call, the way a keeper would.
    function settlePendingBatch(uint256 maxSeed) external {
        calls["settlePendingBatch"]++;
        uint256 current = realm.currentEpoch();
        uint256 settled = realm.settledEpochs();
        if (current <= settled) return;
        uint256 max = bound(maxSeed, 1, 200);
        uint256 alive = aliveTroops();
        uint256 realmBal = token.balanceOf(address(realm));
        uint256 count = realm.settlePending(max);
        uint256 expected = current - settled < max ? current - settled : max;
        assertEq(count, expected);
        assertEq(realm.settledEpochs(), settled + count);
        uint256 aliveAfter = aliveTroops();
        assertLe(aliveAfter, alive, "settlement never creates troops");
        ghostTroopsLost += alive - aliveAfter;
        assertEq(token.balanceOf(address(realm)), realmBal, "settlement moves no tokens");
        ghostSettled = realm.settledEpochs();
    }

    /// @dev Settles one ended epoch with `settleStep(budget)`, doing player actions between the steps.
    function settleStepwise(uint256 budgetSeed, uint256 interleaveSeed) external {
        calls["settleStepwise"]++;
        if (realm.currentEpoch() <= realm.settledEpochs()) {
            try realm.settleStep(0) {
                assertTrue(false, "a zero budget was accepted");
            } catch {}
            return;
        }
        uint256 alive = aliveTroops();
        int256 realmBal = int256(token.balanceOf(address(realm)));
        (uint256 boughtDuring, int256 balanceDelta) = _settleOneEpoch(true, bound(budgetSeed, 1, 6), interleaveSeed);
        uint256 aliveAfter = aliveTroops();
        assertLe(aliveAfter, alive + boughtDuring, "settlement never creates troops");
        ghostTroopsLost += alive + boughtDuring - aliveAfter;
        assertEq(int256(token.balanceOf(address(realm))), realmBal + balanceDelta, "settlement moves no tokens");
        ghostSettled = realm.settledEpochs();
    }

    struct TileSnapshot {
        uint256 tile;
        uint256 holder;
        uint256 garrison;
        Realm.Attack[] attacks;
    }

    function _settleOneEpoch(bool stepwise, uint256 budget, uint256 interleaveSeed)
        internal
        returns (uint256 boughtDuring, int256 balanceDelta)
    {
        uint256 epoch = realm.settledEpochs();
        uint256[] memory tiles = realm.attackedTilesIn(epoch);
        TileSnapshot[] memory snaps = new TileSnapshot[](tiles.length);
        for (uint256 i; i < tiles.length; ++i) {
            (uint256 h, uint256 g) = realm.tile(tiles[i]);
            snaps[i] = TileSnapshot({tile: tiles[i], holder: h, garrison: g, attacks: realm.attacksOn(epoch, tiles[i])});
        }
        if (!stepwise) {
            assertEq(realm.settle(), epoch);
        } else {
            (boughtDuring, balanceDelta) = _stepThrough(epoch, budget, interleaveSeed);
        }
        assertEq(realm.settledEpochs(), epoch + 1);
        (bool started, uint256 done, uint256 total) = realm.settlementProgress();
        assertFalse(started, "progress not cleared");
        assertEq(done, 0);
        assertEq(total, 0, "queued attacks are not settlement progress");
        _checkOutcomes(snaps);
    }

    /// @dev Runs `settleStep(budget)` until the epoch completes. Between steps a player buys troops,
    ///      collects income or declares an attack in the current epoch, so that a half-done
    ///      settlement is observed by ordinary play. Returns troops bought and income paid meanwhile.
    function _stepThrough(uint256 epoch, uint256 budget, uint256 seed)
        internal
        returns (uint256 boughtDuring, int256 balanceDelta)
    {
        bool completed;
        uint256 steps;
        uint256 pendingAfterFirst;
        while (!completed) {
            (, uint256 doneBefore,) = realm.settlementProgress();
            completed = realm.settleStep(budget);
            steps += 1;
            (bool started, uint256 done,) = realm.settlementProgress();
            uint256 pendingNow = _totalPendingIncome();
            if (steps == 1) pendingAfterFirst = pendingNow;
            else assertEq(pendingNow, pendingAfterFirst, "income distributed more than once");
            if (completed) break;
            assertTrue(started);
            _checkActiveProgress(epoch);
            assertGe(done, doneBefore, "tile progress went backwards");
            assertEq(realm.settledEpochs(), epoch, "partial step advanced settledEpochs");
            // One interleaved action per step, chosen by the seed.
            seed = uint256(keccak256(abi.encode(seed, steps)));
            address a = _actor(seed);
            uint256 g = guilds.guildOf(a);
            uint256 choice = (seed >> 8) % 3;
            if (choice == 0 && g != 0) {
                uint256 n = 1 + (seed >> 16) % 5;
                vm.prank(a);
                realm.buyTroops(n);
                boughtDuring += n;
                balanceDelta += int256(n * PRICE - n * PRICE * FEE_BPS / 10_000);
                ghostTroopsBought += n;
                ghostPaidIn += n * PRICE;
            } else if (choice == 1 && g != 0) {
                uint256 got = realm.collectIncome(g);
                assertEq(realm.pendingIncome(g), 0);
                pendingAfterFirst -= got;
                balanceDelta -= int256(got);
            } else if (choice == 2 && g != 0 && realm.reserveOf(g) != 0) {
                uint256 tile = (seed >> 24) % 4;
                (uint256 holder,) = realm.tile(tile);
                if (
                    holder != g && !_alreadyAttacking(g, tile)
                        && !diplomacy.wouldBreakPact(g, holder, realm.currentEpoch())
                ) {
                    vm.prank(a);
                    uint256 pid = guilds.propose(Guilds.Kind.Attack, address(realm), 0, tile, holder, 1);
                    if (guilds.isApproved(pid)) realm.declareAttack(pid);
                }
            }
        }
        assertGe(steps, 1);
    }

    function _checkActiveProgress(uint256 epoch) internal view {
        (, uint256 done, uint256 total) = realm.settlementProgress();
        assertEq(total, realm.attackedTilesIn(epoch).length, "progress must describe the epoch being settled");
        assertLt(done, total);
    }

    function _totalPendingIncome() internal view returns (uint256 total) {
        total = realm.incomeCarry();
        for (uint256 g = 1; g <= guilds.guildCount(); ++g) {
            total += realm.pendingIncome(g);
        }
    }

    /// @dev After an epoch resolves: a tile only changes hands to an attacker that named its holder,
    ///      a tile nobody attacked under its real holder is untouched, and a held tile stays held.
    function _checkOutcomes(TileSnapshot[] memory snaps) internal view {
        for (uint256 i; i < snaps.length; ++i) {
            TileSnapshot memory s = snaps[i];
            (uint256 holder, uint256 garrison) = realm.tile(s.tile);
            bool anyValid;
            bool holderIsNamedAttacker;
            for (uint256 k; k < s.attacks.length; ++k) {
                Realm.Attack memory a = s.attacks[k];
                if (a.expectedHolder != s.holder) continue;
                anyValid = true;
                if (a.attacker == holder) holderIsNamedAttacker = true;
            }
            if (!anyValid) {
                assertEq(holder, s.holder, "a tile changed hands with only void attacks");
                assertEq(garrison, s.garrison, "a tile lost garrison to void attacks");
            } else {
                assertTrue(holder == s.holder || holderIsNamedAttacker, "tile fell to a guild that did not name it");
            }
            if (s.holder != 0) {
                assertTrue(holder != 0, "a held tile became empty");
                assertGe(garrison, 1);
                if (holder == s.holder) assertLe(garrison, s.garrison, "a defender gained troops");
            }
        }
    }

    function collectIncome(uint256 guildSeed) external {
        calls["collectIncome"]++;
        uint256 g = _guild(guildSeed);
        if (g == 0) return;
        uint256 pending = realm.pendingIncome(g);
        uint256 treasury = guilds.treasuryOf(g);
        uint256 got = realm.collectIncome(g);
        assertEq(got, pending);
        assertEq(realm.pendingIncome(g), 0);
        assertEq(guilds.treasuryOf(g), treasury + pending);
        assertEq(realm.collectIncome(g), 0, "collecting twice yields nothing");
    }

    // ------------------------------------------------------------- pacts

    struct PactPlan {
        address a;
        address b;
        uint256 gA;
        uint256 gB;
        uint256 tA;
        uint256 tB;
        uint256 bondA;
        uint256 bondB;
        uint256 epochs;
        uint256 pa;
        uint256 pb;
        bool approved;
    }

    function pact(uint256 actorSeed, uint256 otherSeed, uint256 bondSeedA, uint256 bondSeedB, uint256 epochsSeed)
        external
    {
        calls["pact"]++;
        PactPlan memory s;
        s.a = _actor(actorSeed);
        s.gA = guilds.guildOf(s.a);
        s.gB = _guild(otherSeed);
        if (s.gA == 0 || s.gB == 0 || s.gA == s.gB) return;
        s.b = _anyMemberOf(s.gB);
        if (s.b == address(0)) return;
        if (diplomacy.activePactBetween(s.gA, s.gB) != 0) return;
        if (realm.hasPendingAttack(s.gA, s.gB) || realm.hasPendingAttack(s.gB, s.gA)) return;
        s.tA = guilds.treasuryOf(s.gA);
        s.tB = guilds.treasuryOf(s.gB);
        if (s.tA == 0 || s.tB == 0) return;
        s.bondA = bound(bondSeedA, 1, s.tA);
        s.bondB = bound(bondSeedB, 1, s.tB);
        s.epochs = bound(epochsSeed, 1, 12);
        vm.prank(s.a);
        s.pa = guilds.propose(Guilds.Kind.Pact, address(diplomacy), s.bondA, s.gB, s.epochs, 0);
        vm.prank(s.b);
        s.pb = guilds.propose(Guilds.Kind.Pact, address(diplomacy), s.bondB, s.gA, s.epochs, 0);
        s.approved = _voteAll(s.pa, s.gA, s.a, epochsSeed);
        s.approved = _voteAll(s.pb, s.gB, s.b, bondSeedA) && s.approved;
        _signPact(s);
    }

    function _signPact(PactPlan memory s) internal {
        uint256 dipBal = token.balanceOf(address(diplomacy));
        if (s.approved) {
            uint256 id = diplomacy.sign(s.pa, s.pb);
            Diplomacy.Pact memory p = diplomacy.getPact(id);
            assertEq(uint256(p.status), uint256(Diplomacy.Status.Active));
            assertEq(p.bondA + p.bondB, s.bondA + s.bondB);
            assertEq(p.endEpoch, realm.currentEpoch() + s.epochs - 1);
            assertEq(token.balanceOf(address(diplomacy)), dipBal + s.bondA + s.bondB);
            assertEq(guilds.treasuryOf(s.gA), s.tA - s.bondA);
            assertEq(guilds.treasuryOf(s.gB), s.tB - s.bondB);
            assertEq(diplomacy.activePactBetween(s.gA, s.gB), id);
        } else {
            try diplomacy.sign(s.pa, s.pb) {
                assertTrue(false, "pact signed without both majorities");
            } catch {}
            assertEq(token.balanceOf(address(diplomacy)), dipBal);
            assertEq(guilds.treasuryOf(s.gA), s.tA);
            assertEq(guilds.treasuryOf(s.gB), s.tB);
        }
    }

    function expirePact(uint256 pactSeed) external {
        calls["expirePact"]++;
        uint256 n = diplomacy.pactCount();
        if (n == 0) return;
        uint256 id = bound(pactSeed, 1, n);
        Diplomacy.Pact memory p = diplomacy.getPact(id);
        if (p.status != Diplomacy.Status.Active) {
            try diplomacy.expire(id) {
                assertTrue(false, "a finished pact was expired again");
            } catch {}
            return;
        }
        uint256 tA = guilds.treasuryOf(p.guildA);
        uint256 tB = guilds.treasuryOf(p.guildB);
        if (realm.currentEpoch() <= p.endEpoch) {
            try diplomacy.expire(id) {
                assertTrue(false, "a live pact was expired early");
            } catch {}
            assertEq(guilds.treasuryOf(p.guildA), tA);
            return;
        }
        diplomacy.expire(id);
        assertEq(uint256(diplomacy.getPact(id).status), uint256(Diplomacy.Status.Expired));
        assertEq(guilds.treasuryOf(p.guildA), tA + p.bondA, "bond A returned");
        assertEq(guilds.treasuryOf(p.guildB), tB + p.bondB, "bond B returned");
        assertEq(diplomacy.activePactBetween(p.guildA, p.guildB), 0);
        ghostTerminalStatus[id] = Diplomacy.Status.Expired;
    }

    // ----------------------------------------------------------- seasons

    function closeSeason() external {
        calls["closeSeason"]++;
        uint256 s = nextSeasonToClose;
        (,, bool recorded) = realm.standingsOf(s);
        if (realm.currentSeason() <= s || !recorded) {
            try season.close(s) {
                assertTrue(false, "closed a season that is not over or not settled");
            } catch {}
            return;
        }
        uint256 pool = season.prizePool(s);
        uint256 nextPool = season.prizePool(s + 1);
        season.close(s);
        Season.Result memory r = season.getResult(s);
        assertTrue(r.closed);
        assertEq(r.pool, pool);
        uint256 allocated = r.guildPrize[0] + r.guildPrize[1] + r.guildPrize[2];
        assertEq(allocated + r.rollover, pool, "close allocates exactly the pool");
        assertEq(season.prizePool(s + 1), nextPool + r.rollover, "rollover reaches the next season");
        for (uint256 i; i < 3; ++i) {
            assertEq(r.guildPrize[i], r.perMember[i] * r.memberCount[i]);
            if (r.guildIds[i] != 0) {
                assertEq(r.memberCount[i], guilds.memberCountAt(r.guildIds[i], realm.seasonEnd(s) - 1));
            }
        }
        nextSeasonToClose = s + 1;
        try season.close(s) {
            assertTrue(false, "closed a season twice");
        } catch {}
    }

    function claim(uint256 actorSeed, uint256 seasonSeed) external {
        calls["claim"]++;
        if (nextSeasonToClose == 0) return;
        address a = _actor(actorSeed);
        uint256 s = bound(seasonSeed, 0, nextSeasonToClose - 1);
        Season.Result memory r = season.getResult(s);
        uint256 endInclusive = realm.seasonEnd(s) - 1;
        uint256 rank = 3;
        for (uint256 i; i < 3; ++i) {
            if (r.guildIds[i] != 0 && guilds.wasMemberAt(r.guildIds[i], a, endInclusive)) rank = i;
        }
        if (rank == 3) {
            // Not a winner: try every recorded guild and expect a refusal.
            for (uint256 i; i < 3; ++i) {
                if (r.guildIds[i] == 0) continue;
                vm.prank(a);
                try season.claim(s, r.guildIds[i]) {
                    assertTrue(false, "a non-member claimed a prize");
                } catch {}
            }
            return;
        }
        uint256 g = r.guildIds[rank];
        uint256 balance = token.balanceOf(a);
        uint256 supply = banners.totalSupply();
        if (season.claimed(s, g, a)) {
            vm.prank(a);
            try season.claim(s, g) {
                assertTrue(false, "claimed twice");
            } catch {}
            assertEq(token.balanceOf(a), balance);
            return;
        }
        vm.prank(a);
        (uint256 amount, uint256 tokenId) = season.claim(s, g);
        assertEq(amount, r.perMember[rank]);
        assertEq(token.balanceOf(a), balance + amount);
        assertEq(banners.totalSupply(), supply + 1);
        assertEq(banners.ownerOf(tokenId), a);
        Banners.Banner memory b = banners.bannerOf(tokenId);
        assertEq(b.season, s);
        assertEq(b.guildId, g);
        assertEq(b.rank, rank + 1);
        ghostPaidOut += amount;
        ghostPaidOutTo[a] += amount;
        ghostClaimed[s] += amount;
    }

    function peaceBanner(uint256 guildSeed, uint256 seasonSeed) external {
        calls["peaceBanner"]++;
        uint256 g = _guild(guildSeed);
        uint256 current = realm.currentSeason();
        if (g == 0 || current == 0) return;
        uint256 s = bound(seasonSeed, 0, current - 1);
        bool eligible = !season.peaceBannerMinted(s, g) && guilds.foundedAt(g) < realm.seasonEnd(s)
            && diplomacy.betrayals(g, s) == 0;
        uint256 supply = banners.totalSupply();
        if (!eligible) {
            try season.mintPeaceBanner(s, g) {
                assertTrue(false, "ineligible guild received a peace banner");
            } catch {}
            assertEq(banners.totalSupply(), supply);
            return;
        }
        uint256 tokenId = season.mintPeaceBanner(s, g);
        assertEq(banners.ownerOf(tokenId), address(guilds));
        assertEq(uint256(banners.bannerOf(tokenId).kind), uint256(Banners.BannerKind.Peace));
        assertTrue(season.peaceBannerMinted(s, g));
    }

    // ------------------------------------------------------------- clock

    function warp(uint256 seed) external {
        calls["warp"]++;
        uint256 delta = seed % 4 == 0 ? bound(seed, EPOCH, SEASON) : bound(seed, 1, 2 * EPOCH);
        vm.warp(block.timestamp + delta);
    }
}

/// @notice Properties that must hold after any sequence of player actions.
/// forge-config: default.invariant.runs = 48
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = true
contract PactsInvariantTest is Test {
    uint256 internal constant EPOCH = 1 hours;
    uint256 internal constant SEASON = 7 days;
    uint256 internal constant EPOCHS_PER_SEASON = SEASON / EPOCH;
    uint256 internal constant START = 1_700_000_000;
    uint256 internal constant FUNDS = 1_000_000e18;
    uint256 internal constant ACTORS = 5;

    LaunchToken internal token;
    Guilds internal guilds;
    Realm internal realm;
    Diplomacy internal diplomacy;
    Season internal season;
    Banners internal banners;
    PactsHandler internal handler;
    address[] internal actors;

    function setUp() public {
        vm.warp(START);
        token = new LaunchToken();
        guilds = new Guilds(IERC20(address(token)), EPOCH);
        realm = new Realm(IERC20(address(token)), guilds, EPOCH, SEASON, 1e18, 500);
        diplomacy = realm.diplomacy();
        season = realm.season();
        banners = season.banners();
        for (uint256 i; i < ACTORS; ++i) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(a);
            token.transfer(a, FUNDS);
            vm.prank(a);
            token.approve(address(realm), type(uint256).max);
            vm.prank(a);
            token.approve(address(guilds), type(uint256).max);
        }
        handler = new PactsHandler(token, guilds, realm, diplomacy, season, banners, actors);
        targetContract(address(handler));
    }

    // -------------------------------------------------------- token flows

    /// @dev Reach every new handler branch deterministically as well as in random call sequences.
    function test_queuedAttackHandlerRejectsChangedMembershipAndAllowsOriginalMember() public {
        handler.found(0);
        handler.found(1);
        handler.buyTroops(1, 2);
        handler.attack(1, 0, 2, 1);
        handler.warp(EPOCH);
        handler.settle(1);
        handler.buyTroops(0, 3);
        handler.donate(0, 1, 10e18);
        handler.donate(1, 2, 20e18);
        handler.join(3, 1);
        handler.queueAttack(0, 0, 3, 1);
        handler.pact(0, 2, 10e18, 20e18, 3);
        assertEq(diplomacy.pactCount(), 1);
        handler.join(2, 1);
        handler.declareQueuedAttack(0, 2); // late member
        handler.leave(0);
        handler.declareQueuedAttack(0, 0); // departed proposer
        handler.join(0, 1);
        handler.declareQueuedAttack(0, 0); // rejoined proposer
        assertEq(handler.calls("queuedAttackRejected"), 3);
        assertEq(token.balanceOf(address(diplomacy)), 30e18);
        handler.declareQueuedAttack(0, 3); // uninterrupted original member
        assertEq(handler.calls("queuedAttackDeclared"), 1);
        assertEq(uint256(diplomacy.getPact(1).status), uint256(Diplomacy.Status.Broken));
        assertEq(guilds.treasuryOf(2), 30e18);
        handler.buyTroops(0, 2);
        handler.queueAttack(0, 1, 1, 0);
        handler.declareQueuedAttack(1, 0); // no majority
        handler.queueAttack(0, 1, 1, 1);
        handler.warp(2 * EPOCH);
        handler.declareQueuedAttack(2, 0); // approved, but expired
        assertEq(handler.calls("queuedAttackCreated"), 3);
        assertEq(handler.calls("queuedAttackRejected"), 5);
        assertEq(handler.calls("queuedAttackDeclared"), 1);
        invariant_gameHoldsExactlyWhatWasPaidIn();
        invariant_diplomacyHoldsExactlyTheActiveBonds();
        invariant_guildsHoldsExactlyTheTreasuries();
        invariant_troopsAreOnlyCreatedByPurchaseAndOnlyDestroyedBySettlement();
    }

    function invariant_supplyIsConserved() public view {
        uint256 total = token.balanceOf(address(this)) + token.balanceOf(address(handler));
        for (uint256 i; i < actors.length; ++i) {
            total += token.balanceOf(actors[i]);
        }
        total += _gameBalance();
        assertEq(total, token.totalSupply());
    }

    /// @dev Every token the game holds was paid in by a player; nothing is minted or lost.
    function invariant_gameHoldsExactlyWhatWasPaidIn() public view {
        assertEq(_gameBalance(), handler.ghostPaidIn() - handler.ghostPaidOut());
    }

    /// @dev A player can only ever have been paid what a vote or a season awarded them.
    function invariant_noPlayerReceivesMoreThanAwarded() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertLe(token.balanceOf(actors[i]), FUNDS + handler.ghostPaidOutTo(actors[i]));
        }
    }

    function invariant_guildsHoldsExactlyTheTreasuries() public view {
        uint256 treasuries;
        for (uint256 g = 1; g <= guilds.guildCount(); ++g) {
            treasuries += guilds.treasuryOf(g);
        }
        assertEq(token.balanceOf(address(guilds)), treasuries);
    }

    function invariant_diplomacyHoldsExactlyTheActiveBonds() public view {
        uint256 bonds;
        for (uint256 p = 1; p <= diplomacy.pactCount(); ++p) {
            Diplomacy.Pact memory pact = diplomacy.getPact(p);
            if (pact.status == Diplomacy.Status.Active) bonds += pact.bondA + pact.bondB;
        }
        assertEq(token.balanceOf(address(diplomacy)), bonds);
    }

    function invariant_realmHoldsExactlyTheIncomeItOwes() public view {
        uint256 owed = realm.incomeCarry();
        for (uint256 g = 1; g <= guilds.guildCount(); ++g) {
            owed += realm.pendingIncome(g);
        }
        for (uint256 e = realm.settledEpochs(); e <= realm.currentEpoch(); ++e) {
            owed += realm.incomePool(e);
        }
        assertEq(token.balanceOf(address(realm)), owed);
    }

    function invariant_seasonHoldsExactlyPoolsAndUnclaimedPrizes() public view {
        uint256 owed;
        uint256 closed = handler.nextSeasonToClose();
        for (uint256 s; s < closed; ++s) {
            Season.Result memory r = season.getResult(s);
            owed += r.guildPrize[0] + r.guildPrize[1] + r.guildPrize[2] - handler.ghostClaimed(s);
        }
        for (uint256 s = closed; s <= realm.currentSeason(); ++s) {
            owed += season.prizePool(s);
        }
        assertEq(token.balanceOf(address(season)), owed);
    }

    // ------------------------------------------------------------ troops

    function invariant_troopsAreOnlyCreatedByPurchaseAndOnlyDestroyedBySettlement() public view {
        uint256 alive = handler.aliveTroops();
        assertEq(alive + handler.ghostTroopsLost(), handler.ghostTroopsBought());
        assertLe(alive, handler.ghostTroopsBought());
    }

    function invariant_tileAccountingIsConsistent() public view {
        (uint256[144] memory holders, uint256[144] memory garrisons) = realm.map();
        uint256 held;
        uint256[] memory perGuild = new uint256[](guilds.guildCount() + 1);
        for (uint256 i; i < 144; ++i) {
            if (holders[i] == 0) {
                assertEq(garrisons[i], 0, "an empty tile has no garrison");
            } else {
                assertLe(holders[i], guilds.guildCount(), "holder is a real guild");
                assertGe(garrisons[i], 1, "a held tile is always garrisoned");
                held += 1;
                perGuild[holders[i]] += 1;
            }
        }
        assertEq(realm.heldTiles(), held);
        uint256 sum;
        for (uint256 g = 1; g <= guilds.guildCount(); ++g) {
            assertEq(realm.tilesHeldBy(g), perGuild[g]);
            sum += perGuild[g];
        }
        assertEq(sum, held);
    }

    // -------------------------------------------------------- membership

    function invariant_membershipIsConsistent() public view {
        uint256[] memory counts = new uint256[](guilds.guildCount() + 1);
        for (uint256 i; i < actors.length; ++i) {
            uint256 g = guilds.guildOf(actors[i]);
            if (g == 0) continue;
            assertTrue(guilds.isMember(g, actors[i]));
            assertTrue(guilds.wasMemberAt(g, actors[i], block.timestamp));
            counts[g] += 1;
            // In at most one guild.
            for (uint256 h = 1; h <= guilds.guildCount(); ++h) {
                if (h != g) assertFalse(guilds.isMember(h, actors[i]));
            }
        }
        for (uint256 g = 1; g <= guilds.guildCount(); ++g) {
            assertEq(guilds.memberCountOf(g), counts[g]);
            assertEq(guilds.memberCountAt(g, block.timestamp), counts[g]);
        }
    }

    function invariant_executedProposalsWereApproved() public view {
        for (uint256 p = 1; p <= guilds.proposalCount(); ++p) {
            Guilds.Proposal memory prop = guilds.getProposal(p);
            if (prop.executed) assertTrue(guilds.isApproved(p), "an executed proposal lacked a majority");
            assertLe(prop.yesVotes + prop.noVotes, prop.eligibleVoters, "more votes than eligible voters");
        }
    }

    // ------------------------------------------------------------- pacts

    function invariant_finishedPactsNeverReopen() public view {
        for (uint256 p = 1; p <= diplomacy.pactCount(); ++p) {
            Diplomacy.Pact memory pact = diplomacy.getPact(p);
            Diplomacy.Status terminal = handler.ghostTerminalStatus(p);
            if (terminal != Diplomacy.Status.None) assertEq(uint256(pact.status), uint256(terminal));
            uint256 active = diplomacy.activePactBetween(pact.guildA, pact.guildB);
            if (pact.status == Diplomacy.Status.Active) {
                assertEq(active, p, "an active pact is the pair's active pact");
            } else {
                assertTrue(active != p, "a finished pact is still indexed as active");
            }
        }
    }

    // ------------------------------------------------------------- clock

    function invariant_settlementNeverRunsAhead() public view {
        uint256 settled = realm.settledEpochs();
        assertLe(settled, realm.currentEpoch());
        assertEq(settled, handler.ghostSettled(), "settledEpochs moved outside a settlement call");
        (bool started, uint256 done, uint256 total) = realm.settlementProgress();
        assertFalse(started, "a settlement was left half done");
        assertEq(done, 0);
        assertEq(total, 0, "idle progress exposes queued attacks");
        for (uint256 s; s <= realm.currentSeason(); ++s) {
            (,, bool recorded) = realm.standingsOf(s);
            assertEq(recorded, settled >= (s + 1) * EPOCHS_PER_SEASON);
            if (s < handler.nextSeasonToClose()) assertTrue(season.getResult(s).closed);
        }
    }

    function _gameBalance() internal view returns (uint256) {
        return token.balanceOf(address(realm)) + token.balanceOf(address(guilds)) + token.balanceOf(address(diplomacy))
            + token.balanceOf(address(season));
    }
}
