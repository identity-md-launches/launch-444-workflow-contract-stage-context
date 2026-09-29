// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

/// @title Banners: season trophies
/// @notice A minimal ERC-721 that only the Season contract that created it can mint. Winner banners go
///         to each member of a top-three guild; peace banners go to the Guilds contract on behalf of a
///         guild that finished a season without breaking a pact. Metadata is fully on-chain.
contract Banners {
    enum BannerKind {
        Winner,
        Peace
    }

    struct Banner {
        uint256 season;
        uint256 guildId;
        BannerKind kind;
        uint8 rank; // 1..3 for Winner, 0 for Peace
    }

    string public constant name = "Pact Banners";
    string public constant symbol = "BANNER";

    address public immutable minter;
    uint256 public totalSupply;

    mapping(uint256 tokenId => Banner) internal _banners;
    mapping(uint256 tokenId => address) internal _owners;
    mapping(address owner => uint256) internal _balances;
    mapping(uint256 tokenId => address) internal _approvals;
    mapping(address owner => mapping(address operator => bool)) internal _operators;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event BannerMinted(
        uint256 indexed tokenId,
        address indexed to,
        uint256 indexed season,
        uint256 guildId,
        BannerKind kind,
        uint8 rank
    );

    error NotMinter();
    error ZeroAddress();
    error NoSuchToken();
    error NotAuthorized();
    error WrongFrom();
    error UnsafeRecipient();

    constructor() {
        minter = msg.sender;
    }

    // ----------------------------------------------------------------- mint

    function mint(address to, uint256 season, uint256 guildId, BannerKind kind, uint8 rank)
        external
        returns (uint256 tokenId)
    {
        if (msg.sender != minter) revert NotMinter();
        if (to == address(0)) revert ZeroAddress();
        tokenId = ++totalSupply;
        _banners[tokenId] = Banner({season: season, guildId: guildId, kind: kind, rank: rank});
        _owners[tokenId] = to;
        _balances[to] += 1;
        emit Transfer(address(0), to, tokenId);
        emit BannerMinted(tokenId, to, season, guildId, kind, rank);
    }

    // --------------------------------------------------------------- ERC-721

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 || interfaceId == 0x80ac58cd || interfaceId == 0x5b5e139f;
    }

    function balanceOf(address owner) external view returns (uint256) {
        if (owner == address(0)) revert ZeroAddress();
        return _balances[owner];
    }

    function ownerOf(uint256 tokenId) public view returns (address owner) {
        owner = _owners[tokenId];
        if (owner == address(0)) revert NoSuchToken();
    }

    function bannerOf(uint256 tokenId) external view returns (Banner memory) {
        if (_owners[tokenId] == address(0)) revert NoSuchToken();
        return _banners[tokenId];
    }

    function approve(address to, uint256 tokenId) external {
        address owner = ownerOf(tokenId);
        if (msg.sender != owner && !_operators[owner][msg.sender]) revert NotAuthorized();
        _approvals[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        ownerOf(tokenId);
        return _approvals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operators[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address owner, address operator) external view returns (bool) {
        return _operators[owner][operator];
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        address owner = ownerOf(tokenId);
        if (owner != from) revert WrongFrom();
        if (to == address(0)) revert ZeroAddress();
        if (msg.sender != owner && msg.sender != _approvals[tokenId] && !_operators[owner][msg.sender]) {
            revert NotAuthorized();
        }
        delete _approvals[tokenId];
        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        transferFrom(from, to, tokenId);
        if (to.code.length != 0) {
            bytes4 ret = IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data);
            if (ret != IERC721Receiver.onERC721Received.selector) revert UnsafeRecipient();
        }
    }

    /// @notice On-chain JSON metadata (no external resources).
    function tokenURI(uint256 tokenId) external view returns (string memory) {
        ownerOf(tokenId);
        Banner storage b = _banners[tokenId];
        string memory kind = b.kind == BannerKind.Winner ? "Winner" : "Peace";
        return string.concat(
            "data:application/json;utf8,{\"name\":\"Pact Banner #",
            _toString(tokenId),
            "\",\"description\":\"Pacts season trophy.\",\"attributes\":[{\"trait_type\":\"Kind\",\"value\":\"",
            kind,
            "\"},{\"trait_type\":\"Season\",\"value\":",
            _toString(b.season),
            "},{\"trait_type\":\"Guild\",\"value\":",
            _toString(b.guildId),
            "},{\"trait_type\":\"Rank\",\"value\":",
            _toString(b.rank),
            "}]}"
        );
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(buffer);
    }
}
