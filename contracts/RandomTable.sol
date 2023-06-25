// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./interfaces/IVanilla.sol";

contract RandomTable {
    IVanilla public vanilla;

    uint[] public points;
    uint[] public maxRewardWeights;
    uint[] public minRewardWeights;
    uint public maxNumber;
    uint public divider;
    uint public reinforceVanillaFee;

    event NewReinforceVanillaFee(uint newReinforceVanillaFee);
    event NewTable(
        uint[] newPoints,
        uint[] newMaxRewardWeights,
        uint[] newMinRewardWeights
    );
    event NewDivider(uint newDivider);

    constructor(address newVanilla, uint newMaxNumber) {
        require(newVanilla != address(0), "Vanilla: zero address");
        vanilla = IVanilla(newVanilla);
        maxNumber = newMaxNumber;
    }

    function setReinforceVanillaFee(uint newReinforceVanillaFee) external {
        require(msg.sender == vanilla.admin(), "Vanilla: admin");
        reinforceVanillaFee = newReinforceVanillaFee;

        setTable(points);
        emit NewReinforceVanillaFee(reinforceVanillaFee);
    }

    function setTable(uint[] memory newPoints) public {
        require(msg.sender == vanilla.admin(), "Vanilla: admin");
        require(divider >= 2, "Vanilla: too low divider");

        uint[] memory newMaxRewardWeights = new uint[](newPoints.length);
        uint[] memory newMinRewardWeights = new uint[](newPoints.length);
        for(uint i = 0; i < newPoints.length; i++) {
            uint subtractedPoint = maxNumber - newPoints[i];
            if(i < newPoints.length - 1) {
                uint subtractedPointBefore = maxNumber - newPoints[i+1];
                require(
                    subtractedPointBefore >= subtractedPoint * divider,
                    "Vanilla: invalid point"
                );
            }
            newMaxRewardWeights[i] = safe112(
                maxNumber / subtractedPoint * reinforceVanillaFee
            );
            newMinRewardWeights[i] = newMaxRewardWeights[i] / divider;
        }

        points = newPoints;
        maxRewardWeights = newMaxRewardWeights;
        minRewardWeights = newMinRewardWeights;

        emit NewTable(points, maxRewardWeights, minRewardWeights);
    }

    function setDivider(uint newDivider) external {
        require(msg.sender == vanilla.admin(), "Vanilla: admin");
        require(newDivider >= 2, "Vanilla: too low divider");
        divider = newDivider;
        setTable(points);
        emit NewDivider(divider);
    }

    function getPoints() external view returns (uint[] memory) {
        return points;
    }

    function getMaxRewardWeights() external view returns (uint[] memory) {
        return maxRewardWeights;
    }

    function getMinRewardWeights() external view returns (uint[] memory) {
        return minRewardWeights;
    }

    function getRewardWeight(uint randomNumber) external view returns (uint) {
        uint i = points.length - 1;
        for(; i > 0; i--) {
            if(points[i] <= randomNumber && randomNumber < points[i-1]) {
                break;
            }
        }

        uint rewardWeight = minRewardWeights[i] + (randomNumber % minRewardWeights[i]);
        return rewardWeight > maxRewardWeights[i]
            ? maxRewardWeights[i]
            : rewardWeight;
    }

    function safe112(uint amount) internal pure returns (uint112) {
        require(amount < 2**112, "Vanilla: 112");
        return uint112(amount);
    }
}