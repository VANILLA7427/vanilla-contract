// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./libraries/chainlink/VRFV2WrapperConsumerBase.sol";
import "./interfaces/IERC20.sol";
import "./libraries/SafeERC20.sol";
import "./interfaces/IVanilla.sol";
import "./interfaces/IERC721.sol";
import "./interfaces/IRandomTable.sol";
import "./libraries/ReentrancyGuard.sol";
import "./interfaces/IERC721Receiver.sol";
import "./interfaces/ILoan.sol";

contract Reinforcer is VRFV2WrapperConsumerBase, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    struct ReinforceState {
        address nftOwner;
        uint requestId;
        uint randomNumber;
        bool isPending;
        bool canClaim;
    }
    struct NftState {
        address nft;
        uint tokenId;
    }

    uint32 public callbackGasLimit;
    uint16 public requestConfirmations;
    uint32 public numWords;
    address public wrapperAddress;
    address public link;
    bool public canReinforce;

    IVanilla public vanilla;

    mapping(address => mapping(uint => ReinforceState)) public reinforceStates;
    mapping(uint => NftState) public requestIdToNftStates;

    event CanReinforce(bool canReinforce);
    event NewReinforceRequest(
        address indexed nft,
        uint indexed tokenId,
        address indexed nftOwner,
        uint requestId
    );
    event NewReinforceResponse(
        address indexed nft,
        uint indexed tokenId,
        uint indexed requestId,
        uint newRandomNumber
    );
    event Claim(
        address indexed nft,
        uint indexed tokenId,
        address indexed nftOwner,
        uint newRewardWeight
    );
    event Cancel(
        address indexed nft,
        uint indexed tokenId,
        address indexed nftOwner
    );

    constructor(
        address newVanilla,
        address newLink,
        address newWrapperAddress,
        uint32 newCallbackGasLimit,
        uint16 newRequestConfirmations,
        uint32 newNumWords
    ) VRFV2WrapperConsumerBase(newLink, newWrapperAddress) {
        require(
            newVanilla != address(0) && newLink != address(0) && newWrapperAddress != address(0),
            "Vanilla: zero address"
        );
        vanilla = IVanilla(newVanilla);

        link = newLink;
        wrapperAddress = newWrapperAddress;
        callbackGasLimit = newCallbackGasLimit;
        requestConfirmations = newRequestConfirmations;
        numWords = newNumWords;

        canReinforce = true;
    }

    function setCanReinforce() external {
        require(msg.sender == vanilla.admin(), "Vanilla: admin");
        canReinforce = !canReinforce;
        emit CanReinforce(canReinforce);
    }

    function reinforce(address nft, uint tokenId) external nonReentrant {
        require(canReinforce, "Vanilla: cannot reinforce");
        require(vanilla.allowed721(nft), "Vanilla: not allowed");
        ReinforceState storage reinforceState = reinforceStates[nft][tokenId];
        require(
            !reinforceState.isPending && !reinforceState.canClaim,
            "Vanilla: pending"
        );

        IERC721(nft).safeTransferFrom(msg.sender, address(this), tokenId);
        uint linkBalance = LinkTokenInterface(link).balanceOf(address(this));
        uint reinforceLinkFee = VRF_V2_WRAPPER.calculateRequestPrice(callbackGasLimit);
        if(linkBalance < reinforceLinkFee) {
            IERC20(link).safeTransferFrom(
                msg.sender,
                address(this),
                reinforceLinkFee - linkBalance
            );
        }
        uint reinforceVanillaFee = IRandomTable(vanilla.randomTable()).reinforceVanillaFee();
        uint vanillaBalance = IERC20(address(vanilla)).balanceOf(address(this));
        if(vanillaBalance < reinforceVanillaFee) {
            IERC20(address(vanilla)).safeTransferFrom(
                msg.sender,
                address(this),
                reinforceVanillaFee - vanillaBalance
            );
        }
        IERC20(address(vanilla)).safeTransfer(
            vanilla.treasury(),
            reinforceVanillaFee
        );

        reinforceState.nftOwner = msg.sender;
        reinforceState.isPending = true;
        reinforceState.requestId = requestRandomness(callbackGasLimit, requestConfirmations, numWords);

        requestIdToNftStates[reinforceState.requestId] = NftState(nft, tokenId);

        emit NewReinforceRequest(
            nft,
            tokenId,
            msg.sender,
            reinforceState.requestId
        );
    }

    function cancel(address nft, uint tokenId) external nonReentrant {
        ReinforceState storage reinforceState = reinforceStates[nft][tokenId];
        require(msg.sender == reinforceState.nftOwner, "Vanilla: owner");
        require(
            reinforceState.isPending && !reinforceState.canClaim,
            "Vanilla: cannot cancel"
        );
        reinforceState.isPending = false;

        IERC721(nft).safeTransferFrom(address(this), msg.sender, tokenId);

        emit Cancel(
            nft,
            tokenId,
            msg.sender
        );
    }

    function claim(address nft, uint tokenId) external nonReentrant {
        ReinforceState storage reinforceState = reinforceStates[nft][tokenId];
        require(msg.sender == reinforceState.nftOwner, "Vanilla: owner");
        require(
            !reinforceState.isPending && reinforceState.canClaim,
            "Vanilla: cannot claim"
        );
        reinforceState.canClaim = false;

        uint newRewardWeight = IRandomTable(vanilla.randomTable())
            .getRewardWeight(reinforceState.randomNumber);
        ILoan(vanilla.loan()).setRewardWeight(
            nft,
            tokenId,
            newRewardWeight
        );

        IERC721(nft).safeTransferFrom(address(this), msg.sender, tokenId);

        emit Claim(
            nft,
            tokenId,
            msg.sender,
            newRewardWeight
        );
    }

    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] memory _randomWords
    ) internal override {
        NftState memory nftState = requestIdToNftStates[_requestId];

        ReinforceState storage reinforceState = reinforceStates[nftState.nft][nftState.tokenId];
        if(!reinforceState.isPending) return;
        reinforceState.isPending = false;
        reinforceState.canClaim = true;
        reinforceState.randomNumber = _randomWords[0];

        emit NewReinforceResponse(
            nftState.nft,
            nftState.tokenId,
            _requestId,
            _randomWords[0]
        );
    }

    function calculateVRFRequestPrice() external view returns (uint) {
        return VRF_V2_WRAPPER.calculateRequestPrice(callbackGasLimit);
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}