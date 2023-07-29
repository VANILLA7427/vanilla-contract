// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ILocker {
    function getBoostedAmount(address account, uint amount) external view returns (uint);
}