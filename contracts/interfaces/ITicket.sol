// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ITicket {
    function pendingTokenIds(uint) external view returns (bool);
    function setPendingTokenIds(uint) external;
}