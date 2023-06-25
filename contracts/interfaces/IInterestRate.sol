// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IInterestRate{
    function getBorrowRate(uint, uint, uint) external view returns (uint);
    function utilizationRate(uint, uint, uint) external pure returns (uint);
}