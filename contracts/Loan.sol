// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./interfaces/IERC20.sol";
import "./interfaces/IERC721.sol";
import "./libraries/SafeERC20.sol";
import "./interfaces/IVanilla.sol";
import "./interfaces/IInterestRate.sol";
import "./libraries/ReentrancyGuard.sol";
import "./interfaces/IERC721Receiver.sol";

contract Loan is ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    struct BorrowState {
        uint112 principal;
        uint144 interestIndex;
    }

    IVanilla public vanilla;
    IInterestRate public interestRate;
    uint public collateralFactor;
    uint public reserveFactor;
    uint public accrualBlockNumber;
    uint public borrowIndex;
    uint public totalBorrows;
    uint public totalReserves;
    uint public liquidationIncentive;

    mapping(address => mapping(uint => uint)) public nftToRewardWeights;
    mapping(address => BorrowState) public accountBorrowStates;
    mapping(address => mapping(uint => address)) public ownerOfNft;
    mapping(address => uint) public lockedWeights;
    uint public totalLockedWeight;

    event NewStatus(
        address indexed account,
        uint newTotalBalance,
        uint newTotalBorrows,
        uint newTotalReserves,
        uint newBorrowIndex,
        uint newTotalLockedWeight,
        uint newAccountTotalWeight,
        uint newAccountBorrowPrincipal,
        uint newAccountBorrowIndex
    );
    event AccrueInterest(
        uint borrowRate,
        uint cashPrior,
        uint simpleInterestFactor,
        uint interestAccumulated, 
        uint borrowIndex, 
        uint totalBorrows,
        uint totalReserves
    );
    event CollateralAdded(
        address indexed account,
        address[] nfts,
        uint[] tokenIds,
        uint addedWeight
    );
    event CollateralRemoved(
        address indexed account,
        address[] nfts,
        uint[] tokenIds,
        uint removedWeight
    );
    event Borrow(address indexed account, uint borrowAmount);
    event Repay(address indexed payer, address indexed borrower, uint repayAmount);
    event Liquidate(
        address indexed liquidator,
        address indexed borrower,
        address[] nfts,
        uint[] tokenIds,
        uint liquidatedCollateral,
        uint repayAmount
    );
    event ReservesAdded(address indexed account, uint addAmount);
    event ReservesReduced(uint reduceAmount);
    event NewInterestRate(address newInterestRate);
    event NewCollateralFactor(uint newCollateralFactor);
    event NewReserveFactor(uint newReserveFactor);
    event NewLiquidationIncentive(uint newLiquidationIncentive);
    event NewRewardWeight(
        address indexed nft,
        uint indexed tokenId,
        uint newRewardWeight
    );

    constructor(
        address newVanilla,
        uint newCollateralFactor,
        uint newReserveFactor,
        uint newLiquidationIncentive
    ) {
        require(newVanilla != address(0), "Vanilla: zero address");
        vanilla = IVanilla(newVanilla);

        collateralFactor = newCollateralFactor;
        reserveFactor = newReserveFactor;
        liquidationIncentive = newLiquidationIncentive;
        accrualBlockNumber = block.number;
        borrowIndex = 1e18;
    }

    function getAccountState(
        address account
    )
        external
        view
        returns (
            uint,
            uint,
            uint,
            uint,
            uint,
            uint,
            uint
        )
    {
        return (
            borrowIndex,
            IERC20(address(vanilla)).balanceOf(address(this)),
            totalBorrows,
            totalReserves,
            lockedWeights[account],
            accountBorrowStates[account].principal,
            accountBorrowStates[account].interestIndex
        );
    }

    function borrowBalanceStored(address account) public view returns (uint) {
        return accountBorrowStates[account].interestIndex == 0
            ? 0
            : borrowIndex
                * accountBorrowStates[account].principal
                / accountBorrowStates[account].interestIndex;
    }

    function accrueInterest() public {
        uint currentBlockNumber = block.number;

        if (accrualBlockNumber == currentBlockNumber) {
            return;
        }

        uint totalBalance = IERC20(address(vanilla)).balanceOf(address(this));
        uint borrowRate = interestRate.getBorrowRate(
            totalBalance,
            totalBorrows,
            totalReserves
        );
        if(borrowRate == 0) {
            accrualBlockNumber = currentBlockNumber;
            return;
        }
        uint simpleInterestFactor = borrowRate
            * (currentBlockNumber - accrualBlockNumber);
        uint interestAccumulated = simpleInterestFactor * totalBorrows / 1e18;

        accrualBlockNumber = currentBlockNumber;
        borrowIndex += simpleInterestFactor * borrowIndex / 1e18;
        totalBorrows += interestAccumulated;
        totalReserves += reserveFactor * interestAccumulated / 1e18;

        emit AccrueInterest(
            borrowRate,
            totalBalance,
            simpleInterestFactor,
            interestAccumulated,
            borrowIndex,
            totalBorrows,
            totalReserves
        );
    }

    function addCollateral(
        address[] calldata nfts,
        uint[] calldata tokenIds
    ) external nonReentrant {
        accrueInterest();

        uint totalWeight;
        for (uint i = 0; i < nfts.length; i++) {
            uint weight = nftToRewardWeights[nfts[i]][tokenIds[i]];
            require(weight > 0, "Vanilla: weight");

            IERC721(nfts[i]).safeTransferFrom(msg.sender, address(this), tokenIds[i]);

            ownerOfNft[nfts[i]][tokenIds[i]] = msg.sender;
            totalWeight += weight;
        }
        lockedWeights[msg.sender] += totalWeight;
        totalLockedWeight += totalWeight;

        emit CollateralAdded(
            msg.sender,
            nfts,
            tokenIds,
            totalWeight
        );
        emitNewStatus(msg.sender);
    }

    function removeCollateral(
        address[] calldata nfts,
        uint[] calldata tokenIds
    ) external nonReentrant {
        accrueInterest();
        (, uint shortfall, uint totalWeightToSub) = getAccountLiquidity(
            msg.sender,
            nfts,
            tokenIds,
            0
        );
        require(shortfall == 0, "Vanilla: unsafe");

        for (uint i = 0; i < nfts.length; i++) {
            require(ownerOfNft[nfts[i]][tokenIds[i]] == msg.sender, "Vanilla: owner");
            delete ownerOfNft[nfts[i]][tokenIds[i]];

            IERC721(nfts[i]).safeTransferFrom(address(this), msg.sender, tokenIds[i]);
        }

        lockedWeights[msg.sender] -= totalWeightToSub;
        totalLockedWeight -= totalWeightToSub;

        emit CollateralRemoved(
            msg.sender,
            nfts,
            tokenIds,
            totalWeightToSub
        );
        emitNewStatus(msg.sender);
    }

    function borrow(uint amount) external nonReentrant {
        accrueInterest();
        (,uint shortfall,) = getAccountLiquidity(
            msg.sender,
            new address[](0),
            new uint[](0),
            amount
        );
        require(shortfall == 0, "Vanilla: unsafe");

        uint totalBalance = IERC20(address(vanilla)).balanceOf(address(this));
        require(
            amount > 0 && amount <= (totalBalance - totalReserves),
            "Vanilla: liquidity"
        );

        IERC20(address(vanilla)).safeTransfer(msg.sender, amount);

        accountBorrowStates[msg.sender].principal = safe112(
            borrowBalanceStored(msg.sender) + amount
        );
        accountBorrowStates[msg.sender].interestIndex = safe144(borrowIndex);
        totalBorrows += amount;

        emit Borrow(msg.sender, amount);
        emitNewStatus(msg.sender);
    }

    function repay(address borrower, uint amount) external nonReentrant {
        require(borrower != address(0), "Vanilla: zero address");
        accrueInterest();
        repayInternal(msg.sender, borrower, amount);
        emitNewStatus(borrower);
    }

    function repayInternal(
        address payer,
        address borrower,
        uint amount
    ) internal returns (uint) {
        uint borrowBalance = borrowBalanceStored(borrower);
        if(amount > borrowBalance) {
            amount = borrowBalance;
        }

        IERC20(address(vanilla)).safeTransferFrom(payer, address(this), amount);

        accountBorrowStates[borrower].principal = safe112(borrowBalance - amount);
        accountBorrowStates[borrower].interestIndex = safe144(borrowIndex);
        totalBorrows -= amount;

        emit Repay(payer, borrower, amount);
        return amount;
    }

    function liquidate(
        address borrower,
        address[] calldata nfts,
        uint[] calldata tokenIds,
        uint repayAmount
    ) external nonReentrant {
        accrueInterest();
        require(borrower != address(0), "Vanilla: zero address");
        require(msg.sender != borrower, "Vanilla: self");
        (,uint shortfall,) = getAccountLiquidity(
            borrower,
            new address[](0),
            new uint[](0),
            0
        );
        require(shortfall > 0, "Vanilla: safe");

        repayAmount = repayInternal(msg.sender, borrower, repayAmount);

        uint totalWeightToSub;
        for(uint i = 0; i < nfts.length; i++) {
            require(ownerOfNft[nfts[i]][tokenIds[i]] == borrower, "Vanilla: invalid nft");
            ownerOfNft[nfts[i]][tokenIds[i]] = msg.sender;
            totalWeightToSub += nftToRewardWeights[nfts[i]][tokenIds[i]];
        }

        require(
            totalWeightToSub * collateralFactor * liquidationIncentive / 1e36 <= repayAmount,
            "Vanilla: too cheap"
        );

        lockedWeights[borrower] -= totalWeightToSub;
        lockedWeights[msg.sender] += totalWeightToSub;

        emit Liquidate(
            msg.sender,
            borrower,
            nfts,
            tokenIds,
            totalWeightToSub,
            repayAmount
        );
        emitNewStatus(borrower);
        emitNewStatus(msg.sender);
    }

    function emitNewStatus(address account) private {
        emit NewStatus(
            account,
            IERC20(address(vanilla)).balanceOf(address(this)),
            totalBorrows,
            totalReserves,
            borrowIndex,
            totalLockedWeight,
            lockedWeights[account],
            accountBorrowStates[account].principal,
            accountBorrowStates[account].interestIndex
        );
    }

    function getAccountLiquidity(
        address account,
        address[] memory nfts,
        uint[] memory tokenIds,
        uint borrowAmount
    ) public view returns (uint, uint, uint) {
        uint accountTotalWeight = lockedWeights[account];
        uint totalWeightToSub;
        if(nfts.length > 0) {
            for(uint i = 0; i < nfts.length; i++) {
                totalWeightToSub += nftToRewardWeights[nfts[i]][tokenIds[i]];
            }
            accountTotalWeight -= totalWeightToSub;
        }
        accountTotalWeight = accountTotalWeight * collateralFactor / 1e18;

        uint borrowBalance = borrowBalanceStored(account) + borrowAmount;

        if(accountTotalWeight >= borrowBalance) {
            return (accountTotalWeight - borrowBalance, 0, totalWeightToSub);
        }
        return (0, borrowBalance - accountTotalWeight, totalWeightToSub);
    }

    function addReserves(uint addAmount) external nonReentrant {
        accrueInterest();
        IERC20(address(vanilla)).safeTransferFrom(msg.sender, address(this), addAmount);
        totalReserves += addAmount;
        emit ReservesAdded(msg.sender, addAmount);
    }

    function reduceReserves(address receiver, uint reduceAmount) external nonReentrant {
        require(msg.sender == vanilla.admin(), "Vanilla: admin");
        require(receiver != address(0), "Vanilla: zero address");
        accrueInterest();
        totalReserves -= reduceAmount;
        IERC20(address(vanilla)).safeTransfer(receiver, reduceAmount);
        emit ReservesReduced(reduceAmount);
    }

    function setInterestRate(address newInterestRate) external {
        require(msg.sender == vanilla.admin(), "Vanilla: admin");
        require(newInterestRate != address(0), "Vanilla: zero address");
        if(address(interestRate) != address(0)) {
            accrueInterest();
        }
        interestRate = IInterestRate(newInterestRate);
        emit NewInterestRate(newInterestRate);
    }

    function setReserveFactor(uint newReserveFactor) external {
        require(msg.sender == vanilla.admin(), "Vanilla: admin");
        accrueInterest();
        reserveFactor = newReserveFactor;
        emit NewReserveFactor(newReserveFactor);
    }

    function setCollateralFactor(uint newCollateralFactor) external {
        require(msg.sender == vanilla.admin(), "Vanilla: admin");
        accrueInterest();
        collateralFactor = newCollateralFactor;
        emit NewCollateralFactor(newCollateralFactor);
    }

    function setLiquidationIncentive(uint newLiquidationIncentive) external {
        require(msg.sender == vanilla.admin(), "Vanilla: admin");
        accrueInterest();
        liquidationIncentive = newLiquidationIncentive;
        emit NewLiquidationIncentive(newLiquidationIncentive);
    }

    function setRewardWeight(address nft, uint tokenId, uint rewardWeight) external {
        require(msg.sender == vanilla.reinforcer(), "Vanilla: reinforcer");
        nftToRewardWeights[nft][tokenId] = rewardWeight;
        emit NewRewardWeight(nft, tokenId, rewardWeight);
    }

    function safe112(uint amount) internal pure returns (uint112) {
        require(amount < 2**112, "Vanilla: 112");
        return uint112(amount);
    }

    function safe144(uint amount) internal pure returns (uint144) {
        require(amount < 2**144, "Vanilla: 144");
        return uint144(amount);
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