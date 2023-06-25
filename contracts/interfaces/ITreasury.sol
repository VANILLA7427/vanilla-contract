// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ITreasury {
    function transferFee() external returns (uint);
    function getFeeAmount() external view returns (uint);
}