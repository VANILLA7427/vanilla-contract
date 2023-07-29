// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "./interfaces/IERC20.sol";
import "./libraries/SafeERC20.sol";
import "./interfaces/IVanilla.sol";
import "./interfaces/IVanilla721.sol";
import "./libraries/ReentrancyGuard.sol";
import "./interfaces/IERC721Receiver.sol";

contract Ticket is ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    mapping(uint => mapping(uint => uint)) public ticketPrices;
    mapping(uint => bool) public pendingTokenIds;
    mapping(uint => bool) public ticketIds;

    IVanilla public vanilla;

    event NewTicket(uint indexed ticketId, uint[] tokenIds, uint[] prices);
    event TicketBought(
        uint indexed ticketId,
        uint indexed tokenId,
        address indexed buyer,
        uint price
    );

    constructor (address newVanilla) {
        require(newVanilla != address(0), "Vanilla: zero address");
        vanilla = IVanilla(newVanilla);
    }

    function setPendingTokenIds(uint tokenId) external {
        require(msg.sender == vanilla.vanilla721(), "Vanilla: 721");
        require(!pendingTokenIds[tokenId], "Vanilla: pending id");
        pendingTokenIds[tokenId] = true;
    }

    function newTicket(
        uint ticketId,
        uint[] calldata tokenIds,
        uint[] calldata prices
    ) external {
        require(vanilla.minters(msg.sender), "Vanilla: minter");
        require(!ticketIds[ticketId], "Vanilla: ticket id");
        ticketIds[ticketId] = true;

        for(uint i = 0; i<tokenIds.length; i++) {
            require(!pendingTokenIds[tokenIds[i]], "Vanilla: pending id");
            require(prices[i] > 0, "Vanilla: not correct price");
            pendingTokenIds[tokenIds[i]] = true;
            ticketPrices[ticketId][tokenIds[i]] = prices[i];
        }

        emit NewTicket(ticketId, tokenIds, prices);
    }

    function buy(uint ticketId, uint tokenId) external nonReentrant {
        uint price = ticketPrices[ticketId][tokenId];
        require(price > 0, "Vanilla: sold out");
        delete ticketPrices[ticketId][tokenId];

        IERC20(address(vanilla)).safeTransferFrom(
            msg.sender,
            vanilla.treasury(),
            price
        );

        IVanilla721(vanilla.vanilla721()).mint(msg.sender, tokenId);

        emit TicketBought(
            ticketId,
            tokenId,
            msg.sender,
            price
        );
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}