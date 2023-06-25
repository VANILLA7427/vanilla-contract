// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ILoan {
    function lockedWeights(address) external view returns (uint);
    function totalLockedWeight() external view returns (uint);
    function setRewardWeight(address, uint, uint) external;
}