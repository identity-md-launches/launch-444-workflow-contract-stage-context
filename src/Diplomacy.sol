// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {IRealm} from "./interfaces/IRealm.sol";
import {Guilds} from "./Guilds.sol";

/// @title Diplomacy: pacts backed by token bonds
/// @notice Two guilds sign a pact by each passing a matching Pact proposal that names this contract
///         as target, commits a non-zero bond from the guild treasury and specifies a minimum
///         counter-bond in data3 (zero accepts any non-zero bond). The pact covers a fixed
///         number of epochs starting with the epoch it is signed in. If a guild declares an attack on
///         a pact partner's tile while the pact is active, Realm reports it here at once and the
///         attacker's bond is paid to the victim's treasury together with the victim's own bond. A
///         pact that reaches its end unbroken returns both bonds when anyone calls `expire`.
///
///         Created by Realm in its constructor, so `realm` is `msg.sender` and is trusted for attack
///         reports; nothing else can slash a bond.
contract Diplomacy {
    enum Status {
        None,
        Active,
        Expired,
        Broken
    }

    struct Pact {
        uint256 guildA;
        uint256 guildB;
        uint256 bondA;
        uint256 bondB;
        uint256 startEpoch;
        uint256 endEpoch; // inclusive
        Status status;
    }

    IERC20 public immutable token;
    Guilds public immutable guilds;
    IRealm public immutable realm;

    uint256 public pactCount;
    mapping(uint256 pactId => Pact) internal _pacts;
    /// @dev keyed by (lower guild id, higher guild id); 0 when no active pact.
    mapping(uint256 => mapping(uint256 => uint256)) internal _activePact;
    /// @dev betrayals[guild][season]: number of pacts the guild broke in that season.
    mapping(uint256 guildId => mapping(uint256 season => uint256)) public betrayals;

    event PactSigned(
        uint256 indexed pactId,
        uint256 indexed guildA,
        uint256 indexed guildB,
        uint256 bondA,
        uint256 bondB,
        uint256 startEpoch,
        uint256 endEpoch,
        uint256 proposalA,
        uint256 proposalB
    );
    event PactBroken(
        uint256 indexed pactId, uint256 indexed betrayer, uint256 indexed victim, uint256 slashed, uint256 epoch
    );
    event PactExpired(uint256 indexed pactId);

    error NotRealm();
    error WrongKind();
    error ProposalsDoNotMatch();
    error SameGuild();
    error PactAlreadyActive();
    error AttackPending();
    error NoSuchPact();
    error PactNotActive();
    error PactNotEnded();

    constructor(IERC20 token_, Guilds guilds_) {
        token = token_;
        guilds = guilds_;
        realm = IRealm(msg.sender);
        token_.approve(address(guilds_), type(uint256).max);
    }

    /// @notice Sign a pact from two approved, matching Pact proposals (one per guild). Anyone may call.
    function sign(uint256 proposalA, uint256 proposalB) external returns (uint256 pactId) {
        Guilds.Proposal memory a = guilds.getProposal(proposalA);
        Guilds.Proposal memory b = guilds.getProposal(proposalB);
        _check(a, b);

        // Pull both bonds. Guilds enforces approval, expiry, single use and treasury sufficiency.
        guilds.consume(proposalA);
        guilds.consume(proposalB);

        pactId = _create(a, b);
        emit PactSigned(
            pactId,
            a.guildId,
            b.guildId,
            a.amount,
            b.amount,
            _pacts[pactId].startEpoch,
            _pacts[pactId].endEpoch,
            proposalA,
            proposalB
        );
    }

    function _check(Guilds.Proposal memory a, Guilds.Proposal memory b) internal view {
        if (a.kind != Guilds.Kind.Pact || b.kind != Guilds.Kind.Pact) revert WrongKind();
        if (a.guildId == b.guildId) revert SameGuild();
        // Each side names the other and both agree on the duration (data2 = epochs).
        if (a.data1 != b.guildId || b.data1 != a.guildId || a.data2 != b.data2) revert ProposalsDoNotMatch();
        if (b.amount < a.data3 || a.amount < b.data3) revert ProposalsDoNotMatch();
        (uint256 lo, uint256 hi) = a.guildId < b.guildId ? (a.guildId, b.guildId) : (b.guildId, a.guildId);
        if (_activePact[lo][hi] != 0) revert PactAlreadyActive();
        if (realm.hasPendingAttack(a.guildId, b.guildId) || realm.hasPendingAttack(b.guildId, a.guildId)) {
            revert AttackPending();
        }
    }

    function _create(Guilds.Proposal memory a, Guilds.Proposal memory b) internal returns (uint256 pactId) {
        uint256 startEpoch = realm.currentEpoch();
        pactId = ++pactCount;
        _pacts[pactId] = Pact({
            guildA: a.guildId,
            guildB: b.guildId,
            bondA: a.amount,
            bondB: b.amount,
            startEpoch: startEpoch,
            endEpoch: startEpoch + a.data2 - 1,
            status: Status.Active
        });
        (uint256 lo, uint256 hi) = a.guildId < b.guildId ? (a.guildId, b.guildId) : (b.guildId, a.guildId);
        _activePact[lo][hi] = pactId;
    }

    /// @notice Return both bonds once the pact's last epoch has passed unbroken. Anyone may call.
    function expire(uint256 pactId) external {
        Pact storage p = _pact(pactId);
        if (p.status != Status.Active) revert PactNotActive();
        if (realm.currentEpoch() <= p.endEpoch) revert PactNotEnded();
        _expire(pactId, p);
    }

    /// @notice Called by Realm when `attacker` declares an attack on a tile held by `defender` in `epoch`.
    function onAttack(uint256 attacker, uint256 defender, uint256 epoch) external {
        if (msg.sender != address(realm)) revert NotRealm();
        if (attacker == 0 || defender == 0 || attacker == defender) return;
        (uint256 lo, uint256 hi) = attacker < defender ? (attacker, defender) : (defender, attacker);
        uint256 pactId = _activePact[lo][hi];
        if (pactId == 0) return;
        Pact storage p = _pacts[pactId];
        if (epoch > p.endEpoch) {
            // The pact ran out before this attack; settle it as unbroken.
            _expire(pactId, p);
            return;
        }
        p.status = Status.Broken;
        _activePact[lo][hi] = 0;
        (uint256 slashed, uint256 victimBond) = attacker == p.guildA ? (p.bondA, p.bondB) : (p.bondB, p.bondA);
        betrayals[attacker][realm.seasonOfEpoch(epoch)] += 1;
        emit PactBroken(pactId, attacker, defender, slashed, epoch);
        guilds.deposit(defender, slashed + victimBond);
    }

    function _expire(uint256 pactId, Pact storage p) internal {
        p.status = Status.Expired;
        (uint256 lo, uint256 hi) = p.guildA < p.guildB ? (p.guildA, p.guildB) : (p.guildB, p.guildA);
        _activePact[lo][hi] = 0;
        emit PactExpired(pactId);
        guilds.deposit(p.guildA, p.bondA);
        guilds.deposit(p.guildB, p.bondB);
    }

    // ---------------------------------------------------------------- views

    function getPact(uint256 pactId) external view returns (Pact memory) {
        return _pact(pactId);
    }

    function activePactBetween(uint256 guildA, uint256 guildB) external view returns (uint256) {
        (uint256 lo, uint256 hi) = guildA < guildB ? (guildA, guildB) : (guildB, guildA);
        return _activePact[lo][hi];
    }

    /// @notice True if an attack by `attacker` on `defender` declared in `epoch` would break an active
    ///         pact between them, i.e. `onAttack` would slash rather than expire it.
    function wouldBreakPact(uint256 attacker, uint256 defender, uint256 epoch) external view returns (bool) {
        if (attacker == 0 || defender == 0 || attacker == defender) return false;
        (uint256 lo, uint256 hi) = attacker < defender ? (attacker, defender) : (defender, attacker);
        uint256 pactId = _activePact[lo][hi];
        return pactId != 0 && epoch <= _pacts[pactId].endEpoch;
    }

    function _pact(uint256 pactId) internal view returns (Pact storage p) {
        if (pactId == 0 || pactId > pactCount) revert NoSuchPact();
        p = _pacts[pactId];
    }
}
