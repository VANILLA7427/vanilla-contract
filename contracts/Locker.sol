// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./libraries/SafeERC20.sol";
import "./libraries/BIT.sol";
import "./interfaces/IVanilla.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/ILoan.sol";
import "./libraries/ReentrancyGuard.sol";

contract Locker is ReentrancyGuard, BIT {
    using SafeERC20 for IERC20;

    struct AccountState {
        uint16 lastUnlockStage;
        uint112 lockedAmount;
        uint128 rewardDebt;
    }

    mapping(address => AccountState) public accountStates;

    uint public totalLockedAmount;
    uint public rewardRate;
    uint public blockPeriod;
    uint public boostDivider;
    uint public boostMultiplier;
    uint public startBlock;
    uint public passedStage;

    IVanilla public vanilla;

    event NewBlockPeriod(uint newBlockPeriod);
    event NewBoostDivider(uint newBoostDivider);
    event NewBoostMultiplier(uint newBoostMultiplier);
    event Locked(address indexed account, uint unlockStage, uint amount);
    event Unlocked(address indexed account, uint currentStage, uint amount);
    event LockPeriodIncreased(
        address indexed account,
        uint beforeUnlockStage,
        uint afterUnlockStage,
        uint amount
    );
    event ReceivedReward(address indexed account, uint reward, uint liquidity);

    constructor(
        address newVanilla,
        uint newBlockPeriod,
        uint newBoostDivider,
        uint newBoostMultiplier
    ) {
        require(newVanilla != address(0), "Vanilla: zero address");
        require(newBlockPeriod > 0, "Vanilla: wrong block period");
        vanilla = IVanilla(newVanilla);
        blockPeriod = newBlockPeriod;

        boostDivider = newBoostDivider;
        boostMultiplier = newBoostMultiplier;

        startBlock = block.number;
        passedStage = 0;
    }

    function setBlockPeriod(uint newBlockPeriod) external {
        require(msg.sender == vanilla.admin(), "Vanilla: admin");
        require(newBlockPeriod > 0, "Vanilla: wrong block period");

        uint currentStage = blockNumberToStage(block.number);
        startBlock = block.number;
        passedStage = currentStage;

        blockPeriod = newBlockPeriod;

        emit NewBlockPeriod(newBlockPeriod);
    }

    function setBoostDivider(uint newBoostDivider) external {
        require(msg.sender == vanilla.admin(), "Vanilla: admin");
        boostDivider = newBoostDivider;
        emit NewBoostDivider(boostDivider);
    }

    function setBoostMultiplier(uint newBoostMultiplier) external {
        require(msg.sender == vanilla.admin(), "Vanilla: admin");
        boostMultiplier = newBoostMultiplier;
        emit NewBoostMultiplier(boostMultiplier);
    }

    function lock(
        address account,
        uint unlockBlock,
        uint112 amount
    ) external nonReentrant returns (uint) {
        uint16 currentStage = blockNumberToStage(block.number);
        uint16 unlockStage = blockNumberToStage(unlockBlock);
        require(unlockStage > currentStage + 1 && unlockStage < MAX_STAGE, "Vanilla: period");
        require(amount > 0, "Vanilla: amount");
        require(account != address(0), "Vanilla: zero address");

        claimReward(account);
        AccountState storage accountState = accountStates[account];
        add(account, unlockStage, amount);
        totalLockedAmount += amount;

        accountState.lockedAmount += amount;
        accountState.rewardDebt = safe128(rewardRate * accountState.lockedAmount / 1e18);

        IERC20(address(vanilla)).safeTransferFrom(msg.sender, address(this), amount);

        emit Locked(account, unlockStage, amount);
        return (unlockStage - currentStage) * amount;
    }

    function unlock() external nonReentrant returns (uint) {
        claimReward(msg.sender);

        AccountState storage accountState = accountStates[msg.sender];
        uint lastUnlockStage = accountState.lastUnlockStage;
        uint16 currentStage = blockNumberToStage(block.number);
        if(currentStage > MAX_STAGE - 1) currentStage = MAX_STAGE - 1;

        (, uint unlockAmount) = query(msg.sender, lastUnlockStage, currentStage);

        if(unlockAmount > 0) {
            totalLockedAmount -= unlockAmount;
            accountState.lockedAmount -= safe112(unlockAmount);
            IERC20(address(vanilla)).safeTransfer(msg.sender, unlockAmount);
        }
        accountState.lastUnlockStage = currentStage;
        accountState.rewardDebt = safe128(rewardRate * accountState.lockedAmount / 1e18);

        emit Unlocked(msg.sender, currentStage, unlockAmount);
        return unlockAmount;
    }

    function increaseLockPeriod(
        uint112 amount,
        uint beforeUnlockBlock,
        uint afterUnlockBlock
    ) external nonReentrant {
        uint16 currentStage = blockNumberToStage(block.number);
        uint16 beforeUnlockStage = blockNumberToStage(beforeUnlockBlock);
        uint16 afterUnlockStage = blockNumberToStage(afterUnlockBlock);

        require(beforeUnlockStage < afterUnlockStage, "Vanilla: period");
        require(
            (beforeUnlockStage > currentStage + 1) && beforeUnlockStage < MAX_STAGE,
            "Vanilla: before period"
        );
        require(
            (afterUnlockStage > currentStage + 1) && afterUnlockStage < MAX_STAGE,
            "Vanilla: after period"
        );
        claimReward(msg.sender);
        AccountState storage accountState = accountStates[msg.sender];
        accountState.rewardDebt = safe128(rewardRate * accountState.lockedAmount / 1e18);

        remove(msg.sender, beforeUnlockStage, amount);
        add(msg.sender, afterUnlockStage, amount);
        emit LockPeriodIncreased(
            msg.sender,
            beforeUnlockStage,
            afterUnlockStage,
            amount
        );
    }

    function updateReward() private {
        if(totalLockedAmount == 0) {
            return;
        }
        uint reward = ITreasury(vanilla.treasury()).transferFee();
        if(reward == 0) return;
        rewardRate += reward * 1e18 / totalLockedAmount;
    }

    function claimReward(address account) private {
        updateReward();
        AccountState storage accountState = accountStates[account];

        uint reward = rewardRate
            * accountState.lockedAmount
            / 1e18
            - accountState.rewardDebt;

        if(reward == 0) return;
        uint boostedReward = getBoostedAmount(account, reward);
        uint liquidity = reward - boostedReward;
        if(liquidity > 0) {
            IERC20(address(vanilla)).safeTransfer(vanilla.loan(), liquidity);
        }
        if(boostedReward > 0) {
            IERC20(address(vanilla)).safeTransfer(account, boostedReward);
        }

        emit ReceivedReward(account, reward, liquidity);
    }

    function getWeight(address account) public view returns (uint) {
        uint16 currentStage = blockNumberToStage(block.number);
        if(currentStage > MAX_STAGE - 1) return 0;
        (uint weightSum, uint lockedAmount) = query(account, currentStage, MAX_STAGE - 1);

        uint weightToSub = lockedAmount * currentStage;

        ILoan iLoan = ILoan(vanilla.loan());
        uint loanLockedWeight;
        if(account == address(0)) {
            loanLockedWeight = iLoan.totalLockedWeight();
        } else {
            loanLockedWeight = iLoan.lockedWeights(account);
        }

        return weightSum > weightToSub
            ? weightSum - weightToSub + loanLockedWeight
            : loanLockedWeight;
    }

    function getBoostedAmount(address account, uint amount) public view returns (uint) {
        uint accountWeight = getWeight(account);
        uint totalWeight = getWeight(address(0));

        uint boostedAmount = totalWeight == 0
            ? 0
            : amount * boostMultiplier * accountWeight / totalWeight;
        uint boostedTotal = amount / boostDivider + boostedAmount;
        return boostedTotal > amount ? amount : boostedTotal;
    }

    function getUnlockAmount(
        address account,
        uint blockNumber
    ) external view returns (uint) {
        if(accountStates[account].lastUnlockStage > blockNumberToStage(blockNumber)) {
            return 0;
        }
        (,uint amount) = query(
            account,
            accountStates[account].lastUnlockStage,
            blockNumberToStage(blockNumber)
        );
        return amount;
    }

    function getMaxRewardAmount(address account) external view returns (uint) {
        uint currentRewardRate = rewardRate;
        if(totalLockedAmount != 0) {
            currentRewardRate += ITreasury(vanilla.treasury()).getFeeAmount()
                * 1e18
                / totalLockedAmount;
        }

        AccountState memory accountState = accountStates[account];
        return currentRewardRate
            * accountState.lockedAmount
            / 1e18
            - accountState.rewardDebt;
    }

    function blockNumberToStage(uint blockNumber) public view returns (uint16) {
        return blockNumber < startBlock
            ? uint16(passedStage)
            : uint16((blockNumber - startBlock) / blockPeriod + passedStage);
    }
}