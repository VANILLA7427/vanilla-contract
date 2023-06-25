// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "./interfaces/IERC20.sol";
import "./interfaces/IERC721.sol";
import "./libraries/SafeERC20.sol";
import "./interfaces/IVanilla.sol";
import "./interfaces/ILocker.sol";
import "./libraries/ReentrancyGuard.sol";
import "./interfaces/IERC721Receiver.sol";

contract Auction is ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    struct AuctionState {
        address nft;
        uint tokenId;
        address beneficiary;
        address highestBidder;
        uint32 endBlock;
        bool isLockBid;
        bool highestBidderClaimed;
        bool beneficiaryClaimed;
        uint112 highestBidAmount;
    }

    uint public feePercentage;
    uint public lockBidMinimumWeight;

    IVanilla public vanilla;

    mapping(address => mapping(uint => uint112)) public bidAmounts;
    AuctionState[] public auctionStates;

    event NewFeePercentage(uint newFeePercentage);
    event NewLockBidMinimumWeight(uint newLockBidMinimumWeight);
    event NewAuction(
        address indexed nft,
        uint indexed tokenId,
        uint indexed auctionId,
        address beneficiary,
        uint endBlock,
        uint minimumBidAmount,
        bool isLockBid
    );
    event Bid(
        uint indexed auctionId,
        address indexed bidder,
        bool indexed isLockBid,
        uint highestBidAmount,
        uint transferredAmount
    );
    event Refunded(uint indexed auctionId, address indexed bidder, uint refundedAmount);
    event Claimed(
        uint indexed auctionId,
        address indexed nft,
        uint indexed tokenId,
        address highestBidder
    );
    event BeneficiaryClaimed(
        uint indexed auctionId,
        address indexed nft,
        uint indexed tokenId,
        address beneficiary,
        uint highestBidAmount,
        uint fee
    );

    constructor (
        address newVanilla,
        uint newFeePercentage,
        uint newLockBidMinimumWeight
    ) {
        require(newVanilla != address(0), "Vanilla: zero address");
        vanilla = IVanilla(newVanilla);

        feePercentage = newFeePercentage;
        lockBidMinimumWeight = newLockBidMinimumWeight;
    }

    function setFeePercentage(uint newFeePercentage) external {
        require(msg.sender == vanilla.admin(), "Vanilla: admin");
        feePercentage = newFeePercentage;

        emit NewFeePercentage(feePercentage);
    }

    function setLockBidMinimumWeight(uint newLockBidMinimumWeight) external {
        require(msg.sender == vanilla.admin(), "Vanilla: admin");
        lockBidMinimumWeight = newLockBidMinimumWeight;

        emit NewLockBidMinimumWeight(lockBidMinimumWeight);
    }

    function createAuction(
        address nft,
        uint tokenId,
        address beneficiary,
        uint32 endBlock,
        uint112 minimumBidAmount,
        bool isLockBid
    ) external nonReentrant {
        require(vanilla.allowed721(nft), "Vanilla: not allowed");
        require(endBlock > block.number, "Vanilla: end block");
        require(beneficiary != address(0), "Vanilla: zero address");
        IERC721 iNft = IERC721(nft);

        iNft.safeTransferFrom(msg.sender, address(this), tokenId);

        auctionStates.push(
            AuctionState(
                nft,
                tokenId,
                beneficiary,
                address(0),
                endBlock,
                isLockBid,
                false,
                false,
                minimumBidAmount
            )
        );

        emit NewAuction(
            nft,
            tokenId,
            auctionStates.length - 1,
            beneficiary,
            endBlock,
            minimumBidAmount,
            isLockBid
        );
    }

    function bid(uint auctionId, uint112 bidAmount) external nonReentrant {
        AuctionState storage auctionState = auctionStates[auctionId];
        IERC20 iVanilla = IERC20(address(vanilla));
        require(!auctionState.isLockBid, "Vanilla: lock bid");
        require(block.number < auctionState.endBlock, "Vanilla: over");
        require(auctionState.highestBidAmount < bidAmount, "Vanilla: bid amount");

        uint112 transferAmount = bidAmount - bidAmounts[msg.sender][auctionId];
        iVanilla.safeTransferFrom(msg.sender, address(this), transferAmount);

        bidAmounts[msg.sender][auctionId] = bidAmount;

        auctionState.highestBidAmount = bidAmount;
        auctionState.highestBidder = msg.sender;

        emit Bid(
            auctionId,
            msg.sender,
            false,
            bidAmount,
            transferAmount
        );
    }

    function lockBid(
        uint auctionId,
        uint112 bidAmount,
        uint endBlock
    ) external nonReentrant {
        AuctionState storage auctionState = auctionStates[auctionId];
        IERC20 iVanilla = IERC20(address(vanilla));
        require(auctionState.isLockBid, "Vanilla: not lock bid");
        require(block.number < auctionState.endBlock, "Vanilla: over");

        iVanilla.safeTransferFrom(msg.sender, address(this), bidAmount);

        uint112 newBidAmount;
        {
            address locker = vanilla.locker();
            ILocker iLocker = ILocker(locker);
            require(iLocker.getWeight(msg.sender) > lockBidMinimumWeight, "Vanilla: weight");

            iVanilla.safeApprove(locker, bidAmount);
            newBidAmount = safe112(iLocker.lock(msg.sender, endBlock, bidAmount));
        }

        require(auctionState.highestBidAmount < newBidAmount, "Vanilla: bid amount");

        bidAmounts[msg.sender][auctionId] = newBidAmount;

        auctionState.highestBidAmount = newBidAmount;
        auctionState.highestBidder = msg.sender;

        emit Bid(
            auctionId,
            msg.sender,
            true,
            newBidAmount,
            bidAmount
        );
    }

    function refund(uint auctionId) external nonReentrant {
        AuctionState storage auctionState = auctionStates[auctionId];
        require(!auctionState.isLockBid, "Vanilla: lock bid");
        require(msg.sender != auctionState.highestBidder, "Vanilla: highest bidder");
        uint amount = bidAmounts[msg.sender][auctionId];
        delete bidAmounts[msg.sender][auctionId];

        IERC20(address(vanilla)).safeTransfer(msg.sender, amount);

        emit Refunded(auctionId, msg.sender, amount);
    }

    function claimBeneficiary(uint auctionId) external nonReentrant {
        AuctionState storage auctionState = auctionStates[auctionId];
        require(msg.sender == auctionState.beneficiary, "Vanilla: beneficiary");
        require(!auctionState.isLockBid, "Vanilla: lock bid");
        require(block.number >= auctionState.endBlock, "Vanilla: not over");
        require(!auctionState.beneficiaryClaimed, "Vanilla: claimed");
        auctionState.beneficiaryClaimed = true;

        uint feeAmount;
        uint bidAmount;
        if(auctionState.highestBidder != address(0)) {
            bidAmount = auctionState.highestBidAmount;
            feeAmount = auctionState.highestBidAmount * feePercentage / 1e18;

            IERC20 iVanilla = IERC20(address(vanilla));
            iVanilla.safeTransfer(vanilla.treasury(), feeAmount);
            iVanilla.safeTransfer(
                auctionState.beneficiary,
                auctionState.highestBidAmount - feeAmount
            );
        } else {
            IERC721(auctionState.nft).safeTransferFrom(
                address(this),
                auctionState.beneficiary,
                auctionState.tokenId
            );
        }

        emit BeneficiaryClaimed(
            auctionId,
            auctionState.nft,
            auctionState.tokenId,
            auctionState.beneficiary,
            bidAmount,
            feeAmount
        );
    }

    function claimHighestBidder(uint auctionId) external nonReentrant {
        AuctionState storage auctionState = auctionStates[auctionId];
        require(msg.sender == auctionState.highestBidder, "Vanilla: highest bidder");
        require(!auctionState.isLockBid, "Vanilla: lock bid");
        require(block.number >= auctionState.endBlock, "Vanilla: not over");
        require(!auctionState.highestBidderClaimed, "Vanilla: claimed");
        auctionState.highestBidderClaimed = true;

        IERC721(auctionState.nft).safeTransferFrom(
            address(this),
            msg.sender,
            auctionState.tokenId
        );

        emit Claimed(
            auctionId,
            auctionState.nft,
            auctionState.tokenId,
            msg.sender
        );
    }

    function claimLockBid(uint auctionId) external nonReentrant {
        AuctionState storage auctionState = auctionStates[auctionId];
        require(auctionState.isLockBid, "Vanilla: not lock bid");
        require(block.number >= auctionState.endBlock, "Vanilla: not over");
        require(!auctionState.highestBidderClaimed, "Vanilla: claimed");
        auctionState.highestBidderClaimed = true;

        address nftReceiver = auctionState.highestBidder == address(0)
            ? auctionState.beneficiary
            : auctionState.highestBidder;

        IERC721(auctionState.nft).safeTransferFrom(
            address(this),
            nftReceiver,
            auctionState.tokenId
        );

        emit Claimed(
            auctionId,
            auctionState.nft,
            auctionState.tokenId,
            nftReceiver
        );
    }

    function safe112(uint amount) internal pure returns (uint112) {
        require(amount < 2**112, "Vanilla: 112");
        return uint112(amount);
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