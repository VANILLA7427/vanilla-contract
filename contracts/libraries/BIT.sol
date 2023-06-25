// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract BIT {
    struct WeightState {
        uint128 weightSum;
        uint128 lockedAmount;
    }

    mapping(address => mapping(uint => WeightState)) internal weightStates;

    constructor () {}

    function query(address account, uint from, uint to) internal view returns (uint, uint) {
        (uint weightSumFrom, uint lockedAmountFrom) = query(account, from);
        (uint weightSumTo, uint lockedAmountTo) = query(account, to);
        return (weightSumTo - weightSumFrom, lockedAmountTo - lockedAmountFrom);
    }

    function query(address account, uint to) internal view returns (uint, uint) {
        uint128 weightSum;
        uint128 lockedAmount;
        int i = int(to);
        while(i > 0) {
            WeightState memory weightState = weightStates[account][uint(i)];
            weightSum += weightState.weightSum;
            lockedAmount += weightState.lockedAmount;
            i -= (i & -i);
        }
        return (weightSum, lockedAmount);
    }

    function add(address account, uint128 unlockStage, uint128 amount) internal {
        uint128 weightSum = amount * unlockStage;
        int i = int128(unlockStage);
        while(i<1000) {
            WeightState storage accountWeightState = weightStates[account][uint(i)];
            accountWeightState.weightSum += weightSum;
            accountWeightState.lockedAmount += amount;
            WeightState storage totalWeightState = weightStates[address(0)][uint(i)];
            totalWeightState.weightSum += weightSum;
            totalWeightState.lockedAmount += amount;
            i += (i & -i);
        }
    }

    function remove(address account, uint128 unlockStage, uint128 amount) internal {
        uint128 weightSum = amount * unlockStage;
        int i = int128(unlockStage);
        while(i<1000) {
            WeightState storage accountWeightState = weightStates[account][uint(i)];
            accountWeightState.weightSum -= weightSum;
            accountWeightState.lockedAmount -= amount;
            WeightState storage totalWeightState = weightStates[address(0)][uint(i)];
            totalWeightState.weightSum -= weightSum;
            totalWeightState.lockedAmount -= amount;
            i += (i & -i);
        }
    }

    function safe112(uint n) internal pure returns (uint112) {
        require(n < 2**112, "Vanilla: 112");
        return uint112(n);
    }

    function safe128(uint n) internal pure returns (uint128) {
        require(n < 2**128, "Vanilla: 128");
        return uint128(n);
    }

    function safe16(uint n) internal pure returns (uint16) {
        require(n < 2**16, "Vanilla: 16");
        return uint16(n);
    }
}