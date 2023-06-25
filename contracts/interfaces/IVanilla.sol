// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IVanilla {
    function admin() external view returns (address);
    function receiver() external view returns (address);
    function distributor() external view returns (address);
    function vanilla721() external view returns (address);
    function auction() external view returns (address);
    function locker() external view returns (address);
    function treasury() external view returns (address);
    function trader() external view returns (address);
    function ticket() external view returns (address);
    function loan() external view returns (address);
    function reinforcer() external view returns (address);
    function randomTable() external view returns (address);
    function interestRate() external view returns (address);
    function minters(address) external view returns (bool);
    function allowed721(address) external view returns (bool);
    function mint(address,uint) external;
}