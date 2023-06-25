// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IRandomTable {
    function reinforceVanillaFee() external view returns (uint);
    function getPoints() external view returns (uint[] memory);
    function getRewardWeight(uint) external view returns (uint);
}