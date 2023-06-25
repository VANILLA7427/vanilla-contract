// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./interfaces/IVanilla.sol";

contract InterestRate {
    IVanilla public vanilla;

    uint public multiplierPerBlock;
    uint public baseRatePerBlock;
    uint public jumpMultiplierPerBlock;
    uint public kink;
    uint public blocksPerYear;

    event NewInterestParams(
        uint baseRatePerBlock,
        uint multiplierPerBlock,
        uint jumpMultiplierPerBlock,
        uint kink,
        uint blocksPerYear
    );

    constructor(
        address newVanilla,
        uint newBaseRatePerYear,
        uint newMultiplierPerYear,
        uint newJumpMultiplierPerYear,
        uint newKink,
        uint newBlocksPerYear
    ) {
        require(newVanilla != address(0), "Vanilla: zero address");
        vanilla = IVanilla(newVanilla);

        updateJumpRateModelInternal(
            newBaseRatePerYear,
            newMultiplierPerYear,
            newJumpMultiplierPerYear,
            newKink,
            newBlocksPerYear
        );
    }

    function updateJumpRateModel(
        uint newBaseRatePerYear,
        uint newMultiplierPerYear,
        uint newJumpMultiplierPerYear,
        uint newKink,
        uint newBlocksPerYear
    ) external {
        require(msg.sender == vanilla.admin(), "Vanilla: admin");

        updateJumpRateModelInternal(
            newBaseRatePerYear,
            newMultiplierPerYear,
            newJumpMultiplierPerYear,
            newKink,
            newBlocksPerYear
        );
    }

    function utilizationRate(
        uint balance,
        uint borrows,
        uint reserves
    ) public pure returns (uint) {
        if (borrows == 0) {
            return 0;
        }
        return borrows * 1e18 / (balance + borrows - reserves);
    }

    function getBorrowRate(
        uint balance,
        uint borrows,
        uint reserves
    ) external view returns (uint) {
        return getBorrowRateInternal(balance, borrows, reserves);
    }

    function getBorrowRateInternal(
        uint balance,
        uint borrows,
        uint reserves
    ) internal view returns (uint) {
        uint util = utilizationRate(balance, borrows, reserves);

        if (util <= kink) {
            return util * multiplierPerBlock / 1e18 + baseRatePerBlock;
        }
        uint normalRate = kink * multiplierPerBlock / 1e18 + baseRatePerBlock;
        uint excessUtil = util - kink;
        return excessUtil * jumpMultiplierPerBlock / 1e18 + normalRate;
    }

    function updateJumpRateModelInternal(
        uint newBaseRatePerYear,
        uint newMultiplierPerYear,
        uint newJumpMultiplierPerYear,
        uint newKink,
        uint newBlocksPerYear
    ) internal {
        blocksPerYear = newBlocksPerYear;

        baseRatePerBlock = newBaseRatePerYear / blocksPerYear;
        multiplierPerBlock = newMultiplierPerYear / blocksPerYear;
        jumpMultiplierPerBlock = newJumpMultiplierPerYear / blocksPerYear;
        kink = newKink;

        emit NewInterestParams(
            baseRatePerBlock,
            multiplierPerBlock,
            jumpMultiplierPerBlock,
            kink,
            blocksPerYear
        );
    }
}