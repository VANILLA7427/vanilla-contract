// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "./interfaces/IERC20.sol";
import "./interfaces/IERC721.sol";
import "./libraries/SafeERC20.sol";
import "./interfaces/IVanilla.sol";
import "./libraries/ReentrancyGuard.sol";
import "./interfaces/IERC721Receiver.sol";

contract Trader is ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    struct TradeState {
        address nft;
        uint tokenId;
        address owner;
        bool soldOut;
        uint112 price;
    }

    IVanilla public vanilla;
    TradeState[] public tradeStates;
    uint public feePercentage;

    event NewFeePercentage(uint newFeePercentage);
    event NewTrade(
        address indexed nft,
        uint indexed tokenId,
        uint indexed tradeId,
        address owner,
        uint price
    );
    event TradeSuccess(
        uint indexed tradeId,
        address indexed nft,
        uint indexed tokenId,
        address buyer,
        uint price,
        uint fee
    );
    event TradeCanceled(
        uint indexed tradeId,
        address indexed nft,
        uint indexed tokenId,
        address owner
    );

    constructor (address newVanilla, uint newFeePercentage) {
        require(newVanilla != address(0), "Vanilla: zero address");
        vanilla = IVanilla(newVanilla);

        feePercentage = newFeePercentage;
    }

    function setFeePercentage(uint newFeePercentage) external {
        require(msg.sender == vanilla.admin(), "Vanilla: admin");
        require(newFeePercentage < 1e18, "Vanilla: trade fee");
        feePercentage = newFeePercentage;

        emit NewFeePercentage(feePercentage);
    }

    function newTrade(
        address nft,
        uint tokenId,
        uint112 price
    ) external nonReentrant {
        require(vanilla.allowed721(nft), "Vanilla: not allowed");

        IERC721(nft).safeTransferFrom(msg.sender, address(this), tokenId);

        tradeStates.push(
            TradeState(
                nft,
                tokenId,
                msg.sender,
                false,
                price
            )
        );

        emit NewTrade(
            nft,
            tokenId,
            tradeStates.length - 1,
            msg.sender,
            price
        );
    }

    function buy(uint tradeId) external nonReentrant {
        TradeState storage tradeState = tradeStates[tradeId];
        require(!tradeState.soldOut, "Vanilla: sold out");
        tradeState.soldOut = true;

        uint amount = tradeState.price;
        uint fee = amount * feePercentage / 1e18;

        IERC20 iVanilla = IERC20(address(vanilla));

        iVanilla.safeTransferFrom(msg.sender, tradeState.owner, amount - fee);
        iVanilla.safeTransferFrom(msg.sender, vanilla.treasury(), fee);
        IERC721(tradeState.nft).safeTransferFrom(
            address(this),
            msg.sender,
            tradeState.tokenId
        );

        emit TradeSuccess(
            tradeId,
            tradeState.nft,
            tradeState.tokenId,
            msg.sender,
            amount,
            fee
        );
    }

    function cancel(uint tradeId) external nonReentrant {
        TradeState storage tradeState = tradeStates[tradeId];
        require(msg.sender == tradeState.owner, "Vanilla: owner");
        require(!tradeState.soldOut, "Vanilla: sold out");
        tradeState.soldOut = true;

        IERC721(tradeState.nft).safeTransferFrom(
            address(this),
            msg.sender,
            tradeState.tokenId
        );

        emit TradeCanceled(
            tradeId,
            tradeState.nft,
            tradeState.tokenId,
            tradeState.owner
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