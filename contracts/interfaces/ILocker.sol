// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ILocker {
    function lock(
        address,
        uint,
        uint
    ) external returns (uint);
    function getBoostedAmount(
        address account,
        uint amount
    ) external view returns (uint);
    function getWeight(
        address account
    ) external view returns (uint);
}