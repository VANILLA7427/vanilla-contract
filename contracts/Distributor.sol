// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "./interfaces/IERC20.sol";
import "./libraries/SafeERC20.sol";
import "./interfaces/IVanilla.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/ILocker.sol";
import "./libraries/ReentrancyGuard.sol";

contract Distributor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct AccountState {
        uint144 rewardDebt;
        uint112 deposit;
    }
    struct PoolState {
        address depositToken;
        uint32 lastUpdatedBlock;
        uint64 rewardWeight;
        uint144 rewardRate;
        uint112 totalDeposit;
    }

    address public weth;
    IVanilla public vanilla;

    uint public startBlock;
    uint public totalRewardWeight;

    uint public tokenPerBlock;

    PoolState[] public rewardPoolStates;

    mapping (address => mapping (uint => AccountState)) public accountStates;

    event NewTokenPerBlock(uint tokenPerBlock);
    event NewRewardPool(
        uint indexed poolIdx,
        address rewardPool,
        uint rewardWeight
    );
    event NewRewardWeight(
        uint indexed poolIdx,
        uint rewardWeight
    );
    event Deposit(
        address indexed account,
        uint indexed poolIdx,
        uint deposit
    );
    event Withdrawal(
        address indexed account,
        uint indexed poolIdx,
        uint withdrawAmount
    );
    event ClaimReward(
        address indexed account,
        uint indexed poolIdx,
        uint totalReward,
        uint fee
    );

    constructor (
        address newVanilla,
        address wethAddress,
        uint newStartBlock,
        uint newTokenPerBlock
    ) {
        require(
            newVanilla != address(0) && wethAddress != address(0),
            "Vanilla: zero address"
        );
        vanilla = IVanilla(newVanilla);
        weth = wethAddress;
        startBlock = newStartBlock;
        tokenPerBlock = newTokenPerBlock;
    }

    function setTokenPerBlock(uint newTokenPerBlock) external {
        require(msg.sender == vanilla.admin(), "Vanilla: admin");
        for (uint i = 0; i < rewardPoolStates.length; i++) {
            update(i);
        }
        tokenPerBlock = newTokenPerBlock;
        emit NewTokenPerBlock(tokenPerBlock);
    }

    function addRewardPool(address depositToken, uint64 rewardWeight) external {
        require(msg.sender == vanilla.admin(), "Vanilla: admin");
        require(depositToken != address(0), "Vanilla: zero address");
        for (uint i = 0; i < rewardPoolStates.length; i++) {
            update(i);
        }
        rewardPoolStates.push(
            PoolState(
                depositToken,
                uint32(startBlock > block.number ? startBlock : block.number),
                rewardWeight,
                0,
                0
            )
        );
        totalRewardWeight += rewardWeight;

        emit NewRewardPool(
            rewardPoolStates.length - 1,
            depositToken,
            rewardWeight
        );
    }

    function setRewardWeight(uint poolIdx, uint64 rewardWeight) external {
        require(msg.sender == vanilla.admin(), "Vanilla: admin");
        require(poolIdx < rewardPoolStates.length, "Vanilla: pool");
        for (uint i = 0; i < rewardPoolStates.length; i++) {
            update(i);
        }
        totalRewardWeight = totalRewardWeight
            - rewardPoolStates[poolIdx].rewardWeight
            + rewardWeight;
        rewardPoolStates[poolIdx].rewardWeight = rewardWeight;

        emit NewRewardWeight(poolIdx, rewardWeight);
    }

    function rewardPerPeriod(uint lastUpdatedBlock) public view returns (uint) {
        lastUpdatedBlock = lastUpdatedBlock < startBlock ? startBlock : lastUpdatedBlock;
        if(block.number < lastUpdatedBlock) return 0;
        return (block.number - lastUpdatedBlock) * tokenPerBlock;
    }

    function rewardAmount(uint poolIdx, address account) external view returns (uint) {
        PoolState memory poolState = rewardPoolStates[poolIdx];
        AccountState memory accountState = accountStates[account][poolIdx];

        uint rewardRate = poolState.rewardRate;
        if (block.number > poolState.lastUpdatedBlock && poolState.totalDeposit != 0) {
            rewardRate += rewardPerPeriod(poolState.lastUpdatedBlock)
                * poolState.rewardWeight
                * 1e18
                / totalRewardWeight
                / poolState.totalDeposit;
        }

        uint reward = rewardRate * accountState.deposit / 1e18 - accountState.rewardDebt;
        return ILocker(vanilla.locker()).getBoostedAmount(msg.sender, reward);
    }

    function deposit(uint poolIdx, uint112 amount) external payable nonReentrant {
        require(poolIdx < rewardPoolStates.length, "Vanilla: pool");
        require(amount > 0, "Vanilla: amount");

        AccountState storage accountState = accountStates[msg.sender][poolIdx];
        PoolState storage poolState = rewardPoolStates[poolIdx];

        claim(poolIdx);

        poolState.totalDeposit += amount;
        accountState.deposit += amount;
        accountState.rewardDebt = safe144(
            uint(accountState.deposit) * poolState.rewardRate / 1e18
        );

        if(poolState.depositToken == weth) {
            require(amount == msg.value, "Vanilla: eth amount");
            IWETH(weth).deposit{value: amount}();
        } else {
            IERC20(poolState.depositToken).safeTransferFrom(
                msg.sender,
                address(this),
                amount
            );
        }

        emit Deposit(msg.sender, poolIdx, amount);
    }

    function withdraw(uint poolIdx, uint112 amount) external nonReentrant {
        require(poolIdx < rewardPoolStates.length, "Vanilla: pool");
        require(amount > 0, "Vanilla: amount");

        AccountState storage accountState = accountStates[msg.sender][poolIdx];
        PoolState storage poolState = rewardPoolStates[poolIdx];

        claim(poolIdx);

        poolState.totalDeposit -= amount;
        accountState.deposit -= amount;
        accountState.rewardDebt = safe144(
            uint(accountState.deposit) * poolState.rewardRate / 1e18
        );

        if(poolState.depositToken == weth) {
            IWETH(weth).withdraw(amount);
            payable(msg.sender).transfer(amount);
        } else {
            IERC20(poolState.depositToken).safeTransfer(msg.sender, amount);
        }

        emit Withdrawal(msg.sender, poolIdx, amount);
    }

    function update(uint poolIdx) internal {
        PoolState storage poolState = rewardPoolStates[poolIdx];

        uint currentBlock = block.number;

        if (currentBlock <= poolState.lastUpdatedBlock) {
            return;
        }

        if (poolState.totalDeposit == 0) {
            poolState.lastUpdatedBlock = uint32(currentBlock);
            return;
        }

        uint rewardPerPool = rewardPerPeriod(poolState.lastUpdatedBlock)
            * poolState.rewardWeight
            / totalRewardWeight;

        poolState.rewardRate += safe144(rewardPerPool * 1e18 / poolState.totalDeposit);
        poolState.lastUpdatedBlock = uint32(currentBlock);
    }

    function claim(uint poolIdx) public {
        require(poolIdx < rewardPoolStates.length, "Vanilla: pool");
        AccountState storage accountState = accountStates[msg.sender][poolIdx];

        update(poolIdx);

        if(accountState.deposit == 0) return;
        uint reward = uint(accountState.deposit)
            * rewardPoolStates[poolIdx].rewardRate
            / 1e18
            - accountState.rewardDebt;

        if(reward == 0) return;
        accountState.rewardDebt += safe144(reward);

        uint boostedAmount = ILocker(vanilla.locker()).getBoostedAmount(
            msg.sender,
            reward
        );
        uint fee = reward - boostedAmount;
        if(boostedAmount > 0) {
            vanilla.mint(msg.sender, boostedAmount);
        }
        if(fee > 0) {
            vanilla.mint(vanilla.treasury(), fee);
        }

        emit ClaimReward(
            msg.sender,
            poolIdx,
            reward,
            fee
        );
    }

    function getAllPools()
        external
        view
        returns (
            address[] memory,
            uint[] memory,
            uint[] memory
        )
    {
        address[] memory depositTokens = new address[](rewardPoolStates.length);
        uint[] memory totalDeposits = new uint[](rewardPoolStates.length);
        uint[] memory rewardWeights = new uint[](rewardPoolStates.length);
        for(uint i = 0; i < rewardPoolStates.length; i++) {
            PoolState memory poolState = rewardPoolStates[i];
            depositTokens[i] = poolState.depositToken;
            totalDeposits[i] = poolState.totalDeposit;
            rewardWeights[i] = poolState.rewardWeight;
        }
        return (depositTokens, totalDeposits, rewardWeights);
    }

    function safe144(uint n) internal pure returns (uint144) {
        require(n < 2**144, "Vanilla: 144");
        return uint144(n);
    }

    receive() external payable {
        assert(msg.sender == weth);
    }
}