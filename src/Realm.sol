// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {Guilds} from "./Guilds.sol";
import {Diplomacy} from "./Diplomacy.sol";
import {Season} from "./Season.sol";

/// @title Realm: the 12x12 map, troops, attacks, settlement and tile income
/// @notice Players buy troops with the launch token for their guild. The purchase price, minus the
///         season fee, becomes the income pool of the epoch it was paid in; when that epoch is settled
///         the pool is split equally per tile among the guilds holding tiles. Attacks are declared
///         openly during an epoch from an approved Attack proposal, commit troops from the guild's
///         reserve and name the tile's holder; all attacks on a tile resolve together when the epoch
///         is settled. Anyone can settle an ended epoch; epochs settle in order, and a settlement may
///         be split over several transactions (`settleStep`) so it fits in a block however many
///         attacks were declared.
///
///         Resolution: the single largest force wins the tile; a tie for the largest force, or the
///         holder having the largest force, keeps the holder. Every participant loses troops in
///         proportion to the force it faced: `loss = force * (total - force) / total`. Survivors of
///         the winner garrison the tile; other survivors return to their guild's reserve. An attack
///         whose named holder no longer holds the tile when its epoch is resolved (an earlier epoch,
///         settled later, changed hands) is void: it does not fight and its troops return to the
///         reserve, so an attack can never hit a guild it did not name.
///
///         Realm creates Diplomacy and Season in its constructor and is the only caller they trust.
///         Nothing here is mintable or pausable and no address holds a privileged role.
contract Realm {
    struct Tile {
        uint128 holder; // guild id, 0 = unheld
        uint128 garrison;
    }

    struct Attack {
        uint256 attacker;
        uint256 troops;
        uint256 proposalId;
        uint256 expectedHolder; // holder named by the proposal and checked at declaration
    }

    /// @dev Progress of the settlement of epoch `settledEpochs` when it spans several transactions.
    struct Progress {
        bool started; // income distributed
        uint8 phase; // 0 = current tile not started, 1 = comparing forces, 2 = applying losses
        bool unique; // the largest force so far is unique
        uint256 tileIndex; // next tile of _attackedTiles[epoch]
        uint256 cursor; // next attack of the current tile in the current phase
        uint256 total;
        uint256 best;
        uint256 winner;
        uint256 pool; // for the EpochSettled event
        uint256 held;
    }

    struct Standing {
        uint256[3] guildIds;
        uint256[3] tiles;
        bool recorded;
    }

    uint256 public constant MAP_SIZE = 12;
    uint256 public constant TILE_COUNT = MAP_SIZE * MAP_SIZE;
    uint256 public constant BPS = 10_000;

    IERC20 public immutable token;
    Guilds public immutable guilds;
    Diplomacy public immutable diplomacy;
    Season public immutable season;

    uint256 public immutable genesis;
    uint256 public immutable epochLength;
    uint256 public immutable seasonLength;
    uint256 public immutable epochsPerSeason;
    uint256 public immutable troopPrice; // token minor units per troop
    uint256 public immutable feeBps; // share of every purchase sent to the season prize pool

    Tile[144] internal _tiles;
    mapping(uint256 guildId => uint256) public reserveOf; // unassigned troops
    mapping(uint256 guildId => uint256) public tilesHeldBy;
    uint256 public heldTiles;

    /// @notice Number of settled epochs; also the index of the next epoch to settle.
    uint256 public settledEpochs;
    mapping(uint256 epoch => uint256) public incomePool;
    uint256 public incomeCarry; // rounding dust and income of epochs with no holders
    uint256 public accIncomePerTile;
    mapping(uint256 guildId => uint256) internal _incomeSnapshot;
    mapping(uint256 guildId => uint256) internal _accruedIncome;

    mapping(uint256 epoch => mapping(uint256 tile => Attack[])) internal _attacks;
    mapping(uint256 epoch => uint256[]) internal _attackedTiles;
    mapping(uint256 epoch => mapping(uint256 tile => mapping(uint256 guildId => bool))) internal _attacking;
    mapping(uint256 attacker => mapping(uint256 defender => uint256)) internal _lastAttackEpochPlusOne;
    mapping(uint256 season => Standing) internal _standings;
    Progress internal _progress;

    event TroopsBought(
        uint256 indexed guildId, address indexed payer, uint256 troops, uint256 cost, uint256 fee, uint256 indexed epoch
    );
    event AttackDeclared(
        uint256 indexed epoch,
        uint256 indexed tile,
        uint256 indexed attacker,
        uint256 defender,
        uint256 troops,
        uint256 proposalId
    );
    event AttackResolved(
        uint256 indexed epoch, uint256 indexed tile, uint256 indexed attacker, uint256 committed, uint256 lost, bool won
    );
    event AttackVoided(
        uint256 indexed epoch,
        uint256 indexed tile,
        uint256 indexed attacker,
        uint256 troops,
        uint256 expectedHolder,
        uint256 actualHolder
    );
    event TileResolved(
        uint256 indexed epoch, uint256 indexed tile, uint256 previousHolder, uint256 indexed holder, uint256 garrison
    );
    event EpochSettled(uint256 indexed epoch, uint256 income, uint256 heldTiles, uint256 accIncomePerTile);
    event IncomeCollected(uint256 indexed guildId, uint256 amount);
    event StandingsRecorded(uint256 indexed season, uint256[3] guildIds, uint256[3] tiles);

    error ZeroAddress();
    error InvalidParameters();
    error NotInGuild();
    error ZeroTroops();
    error WrongKind();
    error InvalidTile();
    error HolderChanged(uint256 expected, uint256 actual);
    error CannotAttackOwnTile();
    error AlreadyAttacking();
    error BetrayalRequiresMember();
    error InsufficientTroops(uint256 available, uint256 required);
    error NotWholeTroops();
    error EpochNotEnded();
    error ZeroSteps();
    error TransferFailed();

    constructor(
        IERC20 token_,
        Guilds guilds_,
        uint256 epochLength_,
        uint256 seasonLength_,
        uint256 troopPrice_,
        uint256 feeBps_
    ) {
        if (address(token_) == address(0) || address(guilds_) == address(0)) revert ZeroAddress();
        if (epochLength_ == 0 || seasonLength_ == 0 || seasonLength_ % epochLength_ != 0) revert InvalidParameters();
        if (troopPrice_ == 0 || feeBps_ > BPS) revert InvalidParameters();
        if (guilds_.epochLength() != epochLength_ || address(guilds_.token()) != address(token_)) {
            revert InvalidParameters();
        }
        token = token_;
        guilds = guilds_;
        genesis = guilds_.genesis();
        epochLength = epochLength_;
        seasonLength = seasonLength_;
        epochsPerSeason = seasonLength_ / epochLength_;
        troopPrice = troopPrice_;
        feeBps = feeBps_;
        diplomacy = new Diplomacy(token_, guilds_);
        season = new Season(token_, guilds_, diplomacy);
        token_.approve(address(guilds_), type(uint256).max);
    }

    // ---------------------------------------------------------------- clock

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - genesis) / epochLength;
    }

    function currentSeason() external view returns (uint256) {
        return currentEpoch() / epochsPerSeason;
    }

    function seasonOfEpoch(uint256 epoch) public view returns (uint256) {
        return epoch / epochsPerSeason;
    }

    function epochEnd(uint256 epoch) external view returns (uint256) {
        return genesis + (epoch + 1) * epochLength;
    }

    function seasonEnd(uint256 season_) external view returns (uint256) {
        return genesis + (season_ + 1) * seasonLength;
    }

    // --------------------------------------------------------------- troops

    /// @notice Buy `troops` for the caller's guild, paying `troops * troopPrice` tokens.
    function buyTroops(uint256 troops) external returns (uint256 cost) {
        uint256 guildId = guilds.guildOf(msg.sender);
        if (guildId == 0) revert NotInGuild();
        if (troops == 0) revert ZeroTroops();
        cost = troops * troopPrice;
        if (!token.transferFrom(msg.sender, address(this), cost)) revert TransferFailed();
        _credit(guildId, msg.sender, troops, cost);
    }

    /// @notice Buy troops with a guild's pooled treasury from an approved TreasuryTroops proposal.
    function buyTroopsFromTreasury(uint256 proposalId) external returns (uint256 troops) {
        Guilds.Proposal memory p = guilds.getProposal(proposalId);
        if (p.kind != Guilds.Kind.TreasuryTroops) revert WrongKind();
        if (p.amount % troopPrice != 0) revert NotWholeTroops();
        troops = p.amount / troopPrice;
        if (troops == 0) revert ZeroTroops();
        guilds.consume(proposalId); // transfers p.amount here after checking approval, expiry and use
        _credit(p.guildId, address(guilds), troops, p.amount);
    }

    function _credit(uint256 guildId, address payer, uint256 troops, uint256 cost) internal {
        uint256 fee = cost * feeBps / BPS;
        uint256 epoch = currentEpoch();
        incomePool[epoch] += cost - fee;
        reserveOf[guildId] += troops;
        emit TroopsBought(guildId, payer, troops, cost, fee, epoch);
        if (fee != 0) {
            if (!token.transfer(address(season), fee)) revert TransferFailed();
            season.recordFee(seasonOfEpoch(epoch), fee);
        }
    }

    // -------------------------------------------------------------- attacks

    /// @notice Declare the attack described by an approved Attack proposal in the current epoch.
    ///         Fails if the tile's holder is no longer the one named when the proposal was created.
    ///         Anyone may declare an approved attack, except one that breaks an active pact: betraying
    ///         a partner costs the guild its bond, so only a member of the attacking guild may do it.
    function declareAttack(uint256 proposalId) external returns (uint256 epoch) {
        Guilds.Proposal memory p = guilds.getProposal(proposalId);
        if (p.kind != Guilds.Kind.Attack) revert WrongKind();
        uint256 tile = p.data1;
        uint256 expectedHolder = p.data2;
        uint256 troops = p.data3;
        uint256 attacker = p.guildId;
        if (tile >= TILE_COUNT) revert InvalidTile();
        Tile storage t = _tiles[tile];
        if (t.holder != expectedHolder) revert HolderChanged(expectedHolder, t.holder);
        if (expectedHolder == attacker) revert CannotAttackOwnTile();
        epoch = currentEpoch();
        if (_attacking[epoch][tile][attacker]) revert AlreadyAttacking();
        if (
            expectedHolder != 0 && diplomacy.wouldBreakPact(attacker, expectedHolder, epoch)
                && !guilds.isMember(attacker, msg.sender)
        ) revert BetrayalRequiresMember();
        uint256 available = reserveOf[attacker];
        if (available < troops) revert InsufficientTroops(available, troops);

        guilds.consume(proposalId); // approval, expiry, single use, target == this

        reserveOf[attacker] = available - troops;
        _attacking[epoch][tile][attacker] = true;
        if (_attacks[epoch][tile].length == 0) _attackedTiles[epoch].push(tile);
        _attacks[epoch][tile].push(
            Attack({attacker: attacker, troops: troops, proposalId: proposalId, expectedHolder: expectedHolder})
        );
        _lastAttackEpochPlusOne[attacker][expectedHolder] = epoch + 1;
        emit AttackDeclared(epoch, tile, attacker, expectedHolder, troops, proposalId);
        if (expectedHolder != 0) diplomacy.onAttack(attacker, expectedHolder, epoch);
    }

    // ----------------------------------------------------------- settlement

    /// @notice Settle the next unsettled epoch completely, which must have ended. Anyone may call.
    ///         Finishes a settlement that `settleStep` started.
    function settle() public returns (uint256 epoch) {
        epoch = settledEpochs;
        _settle(type(uint256).max);
    }

    /// @notice Settle the next unsettled epoch in bounded steps: visits at most `maxAttacks` attack
    ///         entries (every attack is visited once to compare forces and once to apply losses) and
    ///         returns whether the epoch is now settled. Income is distributed on the first step and
    ///         standings are recorded on the last; the epoch counts as settled only when it completes.
    ///         Keeps each transaction within a block however many attacks were declared. Anyone may call.
    function settleStep(uint256 maxAttacks) external returns (bool completed) {
        if (maxAttacks == 0) revert ZeroSteps();
        return _settle(maxAttacks);
    }

    /// @notice Settle up to `max` ended epochs in order, each completely. Returns how many were settled.
    function settlePending(uint256 max) external returns (uint256 count) {
        while (count < max && currentEpoch() > settledEpochs) {
            settle();
            count += 1;
        }
    }

    /// @notice Where the settlement of epoch `settledEpochs` stands: whether it has started, how many
    ///         attacked tiles are done and the total. Zero everywhere when no settlement is in progress.
    function settlementProgress() external view returns (bool started, uint256 tilesDone, uint256 tilesTotal) {
        return (_progress.started, _progress.tileIndex, _attackedTiles[settledEpochs].length);
    }

    uint256 internal constant NO_WINNER = type(uint256).max;

    function _settle(uint256 budget) internal returns (bool completed) {
        uint256 epoch = settledEpochs;
        if (currentEpoch() <= epoch) revert EpochNotEnded();
        Progress storage pr = _progress;

        // 1. Income of the epoch goes to the guilds that held tiles during it.
        if (!pr.started) {
            uint256 pool = incomePool[epoch] + incomeCarry;
            uint256 held = heldTiles;
            if (held != 0 && pool != 0) {
                uint256 perTile = pool / held;
                accIncomePerTile += perTile;
                incomeCarry = pool - perTile * held;
            } else {
                incomeCarry = pool;
            }
            pr.started = true;
            pr.pool = pool;
            pr.held = held;
        }

        // 2. All attacks declared in the epoch resolve together, tile by tile, within the budget.
        uint256[] storage attacked = _attackedTiles[epoch];
        uint256 n = attacked.length;
        while (pr.tileIndex < n) {
            if (budget == 0) return false;
            budget = _resolveTile(epoch, attacked[pr.tileIndex], pr, budget);
        }

        // 3. The last epoch of a season fixes the standings.
        if ((epoch + 1) % epochsPerSeason == 0) _recordStandings(seasonOfEpoch(epoch));

        settledEpochs = epoch + 1;
        emit EpochSettled(epoch, pr.pool, pr.held, accIncomePerTile);
        delete _progress;
        return true;
    }

    /// @dev Resolves `tile` as far as `budget` allows and returns what is left of the budget. Advances
    ///      `pr.tileIndex` once the tile is done.
    function _resolveTile(uint256 epoch, uint256 tile, Progress storage pr, uint256 budget) internal returns (uint256) {
        Attack[] storage list = _attacks[epoch][tile];
        Tile storage t = _tiles[tile];
        uint256 holder = t.holder;
        uint256 defense = holder == 0 ? 0 : t.garrison;

        if (pr.phase == 0) {
            pr.phase = 1;
            pr.cursor = 0;
            pr.total = defense;
            pr.best = defense;
            pr.winner = NO_WINNER;
            pr.unique = true;
        }
        if (pr.phase == 1) {
            budget = _compareForces(list, holder, pr, budget);
            if (pr.phase == 1) return budget; // out of budget before the last attack
        }
        budget = _applyLosses(epoch, tile, list, holder, pr, budget);
        if (pr.cursor < list.length) return budget;

        uint256 total = pr.total;
        uint256 winner = pr.winner;
        if (holder != 0) {
            uint256 survivors = defense - defense * (total - defense) / total;
            if (winner == NO_WINNER) t.garrison = uint128(survivors);
            else reserveOf[holder] += survivors;
        }
        if (winner != NO_WINNER) {
            uint256 c = list[winner].troops;
            _setHolder(tile, list[winner].attacker, c - c * (total - c) / total);
        }
        emit TileResolved(epoch, tile, holder, t.holder, t.garrison);
        pr.phase = 0;
        pr.cursor = 0;
        pr.tileIndex += 1;
        return budget;
    }

    /// @dev Phase 1: the unique largest force wins if it is an attacker; a tie for largest keeps the
    ///      holder. Attacks that named a different holder are skipped. Moves to phase 2 when done.
    function _compareForces(Attack[] storage list, uint256 holder, Progress storage pr, uint256 budget)
        internal
        returns (uint256)
    {
        uint256 i = pr.cursor;
        uint256 n = list.length;
        uint256 total = pr.total;
        uint256 best = pr.best;
        uint256 winner = pr.winner;
        bool unique = pr.unique;
        while (i < n && budget != 0) {
            Attack storage a = list[i];
            if (a.expectedHolder == holder) {
                uint256 c = a.troops;
                total += c;
                if (c > best) {
                    best = c;
                    winner = i;
                    unique = true;
                } else if (c == best) {
                    unique = false;
                }
            }
            ++i;
            --budget;
        }
        pr.total = total;
        pr.best = best;
        pr.unique = unique;
        if (i < n) {
            pr.cursor = i;
            pr.winner = winner;
            return 0;
        }
        pr.winner = unique ? winner : NO_WINNER;
        pr.phase = 2;
        pr.cursor = 0;
        return budget;
    }

    /// @dev Phase 2: proportional losses for every attack that fought; a full refund for every attack
    ///      that named a holder who no longer holds the tile.
    function _applyLosses(
        uint256 epoch,
        uint256 tile,
        Attack[] storage list,
        uint256 holder,
        Progress storage pr,
        uint256 budget
    ) internal returns (uint256) {
        uint256 i = pr.cursor;
        uint256 n = list.length;
        uint256 total = pr.total;
        uint256 winner = pr.winner;
        while (i < n && budget != 0) {
            Attack storage a = list[i];
            uint256 c = a.troops;
            if (a.expectedHolder != holder) {
                reserveOf[a.attacker] += c;
                emit AttackVoided(epoch, tile, a.attacker, c, a.expectedHolder, holder);
            } else {
                uint256 loss = c * (total - c) / total;
                emit AttackResolved(epoch, tile, a.attacker, c, loss, i == winner);
                if (i != winner) reserveOf[a.attacker] += c - loss;
            }
            ++i;
            --budget;
        }
        pr.cursor = i;
        return budget;
    }

    function _setHolder(uint256 tile, uint256 newHolder, uint256 garrison) internal {
        Tile storage t = _tiles[tile];
        uint256 old = t.holder;
        if (old != 0) {
            _accrue(old);
            tilesHeldBy[old] -= 1;
        } else {
            heldTiles += 1;
        }
        _accrue(newHolder);
        tilesHeldBy[newHolder] += 1;
        t.holder = uint128(newHolder);
        t.garrison = uint128(garrison);
    }

    function _accrue(uint256 guildId) internal {
        uint256 acc = accIncomePerTile;
        _accruedIncome[guildId] += tilesHeldBy[guildId] * (acc - _incomeSnapshot[guildId]);
        _incomeSnapshot[guildId] = acc;
    }

    function _recordStandings(uint256 season_) internal {
        uint256[3] memory ids;
        uint256[3] memory counts;
        for (uint256 tile; tile < TILE_COUNT; ++tile) {
            uint256 h = _tiles[tile].holder;
            if (h == 0 || h == ids[0] || h == ids[1] || h == ids[2]) continue;
            uint256 c = tilesHeldBy[h];
            for (uint256 i; i < 3; ++i) {
                // More tiles ranks higher; on a tie the older guild (lower id) ranks higher.
                if (c > counts[i] || (c == counts[i] && (ids[i] == 0 || h < ids[i]))) {
                    for (uint256 j = 2; j > i; --j) {
                        ids[j] = ids[j - 1];
                        counts[j] = counts[j - 1];
                    }
                    ids[i] = h;
                    counts[i] = c;
                    break;
                }
            }
        }
        Standing storage s = _standings[season_];
        s.guildIds = ids;
        s.tiles = counts;
        s.recorded = true;
        emit StandingsRecorded(season_, ids, counts);
    }

    // --------------------------------------------------------------- income

    /// @notice Move a guild's accrued tile income into its pooled treasury in Guilds. Anyone may call.
    function collectIncome(uint256 guildId) external returns (uint256 amount) {
        _accrue(guildId);
        amount = _accruedIncome[guildId];
        _accruedIncome[guildId] = 0;
        emit IncomeCollected(guildId, amount);
        if (amount != 0) guilds.deposit(guildId, amount);
    }

    function pendingIncome(uint256 guildId) external view returns (uint256) {
        return _accruedIncome[guildId] + tilesHeldBy[guildId] * (accIncomePerTile - _incomeSnapshot[guildId]);
    }

    // ---------------------------------------------------------------- views

    function tile(uint256 tileId) external view returns (uint256 holder, uint256 garrison) {
        if (tileId >= TILE_COUNT) revert InvalidTile();
        Tile storage t = _tiles[tileId];
        return (t.holder, t.garrison);
    }

    /// @notice Every tile's holder and garrison, for building the map in one call.
    function map() external view returns (uint256[144] memory holders, uint256[144] memory garrisons) {
        for (uint256 i; i < TILE_COUNT; ++i) {
            holders[i] = _tiles[i].holder;
            garrisons[i] = _tiles[i].garrison;
        }
    }

    function attacksOn(uint256 epoch, uint256 tileId) external view returns (Attack[] memory) {
        return _attacks[epoch][tileId];
    }

    function attackedTilesIn(uint256 epoch) external view returns (uint256[] memory) {
        return _attackedTiles[epoch];
    }

    function isEpochSettled(uint256 epoch) external view returns (bool) {
        return epoch < settledEpochs;
    }

    /// @notice True while `attacker` has declared an attack on `defender`'s tile in an epoch not yet settled.
    function hasPendingAttack(uint256 attacker, uint256 defender) external view returns (bool) {
        return _lastAttackEpochPlusOne[attacker][defender] > settledEpochs;
    }

    function standingsOf(uint256 season_)
        external
        view
        returns (uint256[3] memory guildIds, uint256[3] memory tiles, bool recorded)
    {
        Standing storage s = _standings[season_];
        return (s.guildIds, s.tiles, s.recorded);
    }
}
