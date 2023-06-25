// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./interfaces/IVanilla.sol";
import "./libraries/SafeERC20.sol";

contract Treasury{
    using SafeERC20 for IERC20;

    IVanilla public vanilla;

    constructor(address newVanilla) {
        require(newVanilla != address(0), "Vanilla: zero address");
        vanilla = IVanilla(newVanilla);
    }

    function transferFee() external returns (uint amount) {
        address locker = vanilla.locker();
        require(msg.sender == locker, "Vanilla: locker");
        IERC20 iVanilla = IERC20(address(vanilla));
        amount = iVanilla.balanceOf(address(this));
        iVanilla.safeTransfer(locker, amount);
    }

    function getFeeAmount() external view returns (uint) {
        return IERC20(address(vanilla)).balanceOf(address(this));
    }
}