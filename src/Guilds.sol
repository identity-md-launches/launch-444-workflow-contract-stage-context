// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {IRealm} from "./interfaces/IRealm.sol";

/// @title Guilds: membership, one-member-one-vote proposals and pooled treasuries
/// @notice Anyone can found or join a guild. Every action that spends a guild's pooled treasury,
///         attacks, signs a pact or expels a member is a proposal that needs a strict majority of the
///         members who had joined before the proposal was created. Proposals expire at the end of the
///         epoch after the one they were created in. There are no admin functions.
///
///         Guilds also keeps the shared epoch clock: `genesis` is the deployment time and epochs are
///         `epochLength` seconds long. Realm checks at construction that it uses the same clock.
///
///         Proposal kinds executed here: Expel and Payout (`execute`). Proposal kinds consumed by a
///         named game contract: TreasuryTroops (Realm), Attack (Realm) and Pact (Diplomacy), via
///         `consume`, which also releases the proposal's `amount` from the treasury to that contract.
contract Guilds {
    enum Kind {
        Expel, // target = member to expel
        Payout, // target = recipient, amount = tokens paid from the treasury
        TreasuryTroops, // target = Realm, amount = tokens spent on troops
        Attack, // target = Realm, data1 = tile, data2 = expected holder guild, data3 = troops
        Pact // target = Diplomacy, amount = bond, data1 = other guild, data2 = epochs, data3 = minimum counter-bond
    }

    struct Guild {
        string name;
        uint64 foundedAt;
        uint256 memberCount;
        uint256 treasury;
        uint256 joinSeq;
    }

    struct Member {
        bool active;
        uint256 seq;
    }

    /// @dev One stint per join. `leftAt == 0` while the stint is open.
    struct Stint {
        uint64 joinedAt;
        uint64 leftAt;
    }

    struct Checkpoint {
        uint64 timestamp;
        uint192 count;
    }

    struct Proposal {
        uint256 guildId;
        Kind kind;
        address proposer;
        address target;
        uint256 amount;
        uint256 data1;
        uint256 data2;
        uint256 data3;
        uint256 createdEpoch;
        uint256 seqAtCreation;
        uint256 eligibleVoters;
        uint256 yesVotes;
        uint256 noVotes;
        bool executed;
    }

    IERC20 public immutable token;
    uint256 public immutable epochLength;
    uint256 public immutable genesis;

    uint256 public guildCount;
    uint256 public proposalCount;

    mapping(uint256 guildId => Guild) internal _guilds;
    mapping(uint256 guildId => mapping(address member => Member)) internal _members;
    mapping(uint256 guildId => mapping(address member => Stint[])) internal _stints;
    mapping(uint256 guildId => Checkpoint[]) internal _countHistory;
    mapping(address member => uint256 guildId) public guildOf;
    mapping(uint256 proposalId => Proposal) internal _proposals;
    mapping(uint256 proposalId => mapping(address voter => bool)) public hasVoted;

    event GuildFounded(uint256 indexed guildId, string name, address indexed founder);
    event MemberJoined(uint256 indexed guildId, address indexed member, uint256 seq);
    event MemberLeft(uint256 indexed guildId, address indexed member);
    event MemberExpelled(uint256 indexed guildId, address indexed member, uint256 indexed proposalId);
    event ProposalCreated(
        uint256 indexed proposalId,
        uint256 indexed guildId,
        Kind kind,
        address indexed proposer,
        address target,
        uint256 amount,
        uint256 data1,
        uint256 data2,
        uint256 data3,
        uint256 createdEpoch,
        uint256 eligibleVoters
    );
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 yesVotes, uint256 noVotes);
    event ProposalApproved(uint256 indexed proposalId);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalConsumed(uint256 indexed proposalId, address indexed consumer, uint256 amount);
    event TreasuryDeposited(uint256 indexed guildId, address indexed from, uint256 amount);
    event TreasuryPaid(uint256 indexed guildId, address indexed to, uint256 amount, uint256 indexed proposalId);

    error ZeroAddress();
    error InvalidEpochLength();
    error InvalidName();
    error AlreadyInGuild();
    error NotInGuild();
    error NoSuchGuild();
    error NoSuchProposal();
    error NotMember();
    error NotEligibleVoter();
    error AlreadyVoted();
    error ProposalExpired();
    error ProposalNotApproved();
    error ProposalAlreadyExecuted();
    error WrongKind();
    error NotTarget();
    error InvalidProposal();
    error InsufficientTreasury(uint256 available, uint256 required);
    error TransferFailed();

    constructor(IERC20 token_, uint256 epochLength_) {
        if (address(token_) == address(0)) revert ZeroAddress();
        if (epochLength_ == 0) revert InvalidEpochLength();
        token = token_;
        epochLength = epochLength_;
        genesis = block.timestamp;
    }

    // ---------------------------------------------------------------- clock

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - genesis) / epochLength;
    }

    // ----------------------------------------------------------- membership

    function found(string calldata name) external returns (uint256 guildId) {
        if (guildOf[msg.sender] != 0) revert AlreadyInGuild();
        uint256 len = bytes(name).length;
        if (len == 0 || len > 32) revert InvalidName();
        guildId = ++guildCount;
        Guild storage g = _guilds[guildId];
        g.name = name;
        g.foundedAt = uint64(block.timestamp);
        emit GuildFounded(guildId, name, msg.sender);
        _join(guildId, msg.sender);
    }

    function join(uint256 guildId) external {
        if (guildOf[msg.sender] != 0) revert AlreadyInGuild();
        if (guildId == 0 || guildId > guildCount) revert NoSuchGuild();
        _join(guildId, msg.sender);
    }

    function leave() external {
        uint256 guildId = guildOf[msg.sender];
        if (guildId == 0) revert NotInGuild();
        _leave(guildId, msg.sender);
        emit MemberLeft(guildId, msg.sender);
    }

    function _join(uint256 guildId, address account) internal {
        Guild storage g = _guilds[guildId];
        Member storage m = _members[guildId][account];
        m.active = true;
        m.seq = ++g.joinSeq;
        _stints[guildId][account].push(Stint({joinedAt: uint64(block.timestamp), leftAt: 0}));
        g.memberCount += 1;
        guildOf[account] = guildId;
        _checkpoint(guildId, g.memberCount);
        emit MemberJoined(guildId, account, m.seq);
    }

    function _leave(uint256 guildId, address account) internal {
        Guild storage g = _guilds[guildId];
        Member storage m = _members[guildId][account];
        m.active = false;
        Stint[] storage stints = _stints[guildId][account];
        stints[stints.length - 1].leftAt = uint64(block.timestamp);
        g.memberCount -= 1;
        guildOf[account] = 0;
        _checkpoint(guildId, g.memberCount);
    }

    function _checkpoint(uint256 guildId, uint256 count) internal {
        Checkpoint[] storage history = _countHistory[guildId];
        uint256 len = history.length;
        if (len > 0 && history[len - 1].timestamp == uint64(block.timestamp)) {
            history[len - 1].count = uint192(count);
        } else {
            history.push(Checkpoint({timestamp: uint64(block.timestamp), count: uint192(count)}));
        }
    }

    // ------------------------------------------------------------ proposals

    /// @notice Create a proposal for the caller's guild. The proposer's own yes vote is cast at once.
    function propose(Kind kind, address target, uint256 amount, uint256 data1, uint256 data2, uint256 data3)
        external
        returns (uint256 proposalId)
    {
        uint256 guildId = guildOf[msg.sender];
        if (guildId == 0) revert NotInGuild();
        if (target == address(0)) revert ZeroAddress();

        if (kind == Kind.Expel) {
            if (amount != 0) revert InvalidProposal();
        } else if (kind == Kind.Payout || kind == Kind.TreasuryTroops) {
            if (amount == 0) revert InvalidProposal();
        } else if (kind == Kind.Attack) {
            if (amount != 0 || data3 == 0) revert InvalidProposal();
            (uint256 holder,) = IRealm(target).tile(data1);
            if (holder != data2) revert InvalidProposal();
        } else if (kind == Kind.Pact) {
            if (amount == 0 || data2 == 0) revert InvalidProposal();
            if (data1 == 0 || data1 > guildCount || data1 == guildId) revert InvalidProposal();
        }

        Guild storage g = _guilds[guildId];
        proposalId = ++proposalCount;
        Proposal storage p = _proposals[proposalId];
        p.guildId = guildId;
        p.kind = kind;
        p.proposer = msg.sender;
        p.target = target;
        p.amount = amount;
        p.data1 = data1;
        p.data2 = data2;
        p.data3 = data3;
        p.createdEpoch = currentEpoch();
        p.seqAtCreation = g.joinSeq;
        p.eligibleVoters = g.memberCount;

        emit ProposalCreated(
            proposalId, guildId, kind, msg.sender, target, amount, data1, data2, data3, p.createdEpoch, g.memberCount
        );
        _vote(proposalId, p, msg.sender, true);
    }

    /// @notice Vote on a proposal of the caller's guild. Only members who joined before the proposal
    ///         was created may vote, one vote each, and votes cannot be changed.
    function vote(uint256 proposalId, bool support) external {
        Proposal storage p = _proposal(proposalId);
        if (isExpired(proposalId)) revert ProposalExpired();
        _vote(proposalId, p, msg.sender, support);
    }

    function _vote(uint256 proposalId, Proposal storage p, address voter, bool support) internal {
        Member storage m = _members[p.guildId][voter];
        if (!m.active || m.seq > p.seqAtCreation) revert NotEligibleVoter();
        if (hasVoted[proposalId][voter]) revert AlreadyVoted();
        hasVoted[proposalId][voter] = true;
        bool approvedBefore = _approved(p);
        if (support) p.yesVotes += 1;
        else p.noVotes += 1;
        emit VoteCast(proposalId, voter, support, p.yesVotes, p.noVotes);
        if (!approvedBefore && _approved(p)) emit ProposalApproved(proposalId);
    }

    /// @notice Execute an approved Expel or Payout proposal. Anyone may call.
    function execute(uint256 proposalId) external {
        Proposal storage p = _proposal(proposalId);
        if (p.kind != Kind.Expel && p.kind != Kind.Payout) revert WrongKind();
        _ready(proposalId, p);
        p.executed = true;
        if (p.kind == Kind.Expel) {
            if (!_members[p.guildId][p.target].active) revert NotMember();
            _leave(p.guildId, p.target);
            emit MemberExpelled(p.guildId, p.target, proposalId);
        } else {
            _spend(p.guildId, p.amount);
            emit TreasuryPaid(p.guildId, p.target, p.amount, proposalId);
            if (!token.transfer(p.target, p.amount)) revert TransferFailed();
        }
        emit ProposalExecuted(proposalId);
    }

    /// @notice Consume an approved TreasuryTroops, Attack or Pact proposal. Only the proposal's named
    ///         target contract may call; the proposal's `amount` is released from the guild treasury to it.
    function consume(uint256 proposalId) external returns (Proposal memory) {
        Proposal storage p = _proposal(proposalId);
        if (p.kind == Kind.Expel || p.kind == Kind.Payout) revert WrongKind();
        if (msg.sender != p.target) revert NotTarget();
        _ready(proposalId, p);
        p.executed = true;
        if (p.amount != 0) {
            _spend(p.guildId, p.amount);
            if (!token.transfer(msg.sender, p.amount)) revert TransferFailed();
        }
        emit ProposalConsumed(proposalId, msg.sender, p.amount);
        return p;
    }

    function _ready(uint256 proposalId, Proposal storage p) internal view {
        if (p.executed) revert ProposalAlreadyExecuted();
        if (isExpired(proposalId)) revert ProposalExpired();
        if (!_approved(p)) revert ProposalNotApproved();
    }

    function _spend(uint256 guildId, uint256 amount) internal {
        Guild storage g = _guilds[guildId];
        if (g.treasury < amount) revert InsufficientTreasury(g.treasury, amount);
        g.treasury -= amount;
    }

    // ------------------------------------------------------------- treasury

    /// @notice Deposit tokens into a guild's pooled treasury. Used by Realm (tile income), Diplomacy
    ///         (bond returns and slashes) and anyone who wants to donate.
    function deposit(uint256 guildId, uint256 amount) external {
        if (guildId == 0 || guildId > guildCount) revert NoSuchGuild();
        if (!token.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        _guilds[guildId].treasury += amount;
        emit TreasuryDeposited(guildId, msg.sender, amount);
    }

    // ---------------------------------------------------------------- views

    function getGuild(uint256 guildId)
        external
        view
        returns (string memory name, uint64 foundedAt, uint256 memberCount, uint256 treasury)
    {
        Guild storage g = _guilds[guildId];
        return (g.name, g.foundedAt, g.memberCount, g.treasury);
    }

    function treasuryOf(uint256 guildId) external view returns (uint256) {
        return _guilds[guildId].treasury;
    }

    function memberCountOf(uint256 guildId) external view returns (uint256) {
        return _guilds[guildId].memberCount;
    }

    function foundedAt(uint256 guildId) external view returns (uint64) {
        return _guilds[guildId].foundedAt;
    }

    function isMember(uint256 guildId, address account) external view returns (bool) {
        return _members[guildId][account].active;
    }

    function memberSeq(uint256 guildId, address account) external view returns (uint256) {
        return _members[guildId][account].seq;
    }

    function stintCount(uint256 guildId, address account) external view returns (uint256) {
        return _stints[guildId][account].length;
    }

    function stintAt(uint256 guildId, address account, uint256 index) external view returns (Stint memory) {
        return _stints[guildId][account][index];
    }

    /// @notice Whether `account` was a member of `guildId` at `timestamp` (inclusive bounds on join,
    ///         exclusive on leave).
    function wasMemberAt(uint256 guildId, address account, uint256 timestamp) external view returns (bool) {
        Stint[] storage stints = _stints[guildId][account];
        uint256 i = stints.length;
        while (i > 0) {
            i -= 1;
            Stint storage s = stints[i];
            if (s.joinedAt > timestamp) continue;
            return s.leftAt == 0 || s.leftAt > timestamp;
        }
        return false;
    }

    /// @notice Member count of `guildId` as of `timestamp` (after every change made at or before it).
    function memberCountAt(uint256 guildId, uint256 timestamp) external view returns (uint256) {
        Checkpoint[] storage history = _countHistory[guildId];
        uint256 low = 0;
        uint256 high = history.length;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (history[mid].timestamp <= timestamp) low = mid + 1;
            else high = mid;
        }
        return low == 0 ? 0 : history[low - 1].count;
    }

    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return _proposal(proposalId);
    }

    function isApproved(uint256 proposalId) external view returns (bool) {
        return _approved(_proposal(proposalId));
    }

    /// @notice A proposal created in epoch E can be voted on and executed through the end of epoch E+1.
    function isExpired(uint256 proposalId) public view returns (bool) {
        return currentEpoch() > _proposal(proposalId).createdEpoch + 1;
    }

    function _approved(Proposal storage p) internal view returns (bool) {
        return p.yesVotes * 2 > p.eligibleVoters;
    }

    function _proposal(uint256 proposalId) internal view returns (Proposal storage p) {
        if (proposalId == 0 || proposalId > proposalCount) revert NoSuchProposal();
        p = _proposals[proposalId];
    }
}
