// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./interfaces/IVanilla.sol";
import "./libraries/ERC721Enumerable.sol";
import "./interfaces/ITicket.sol";

contract Vanilla721 is ERC721Enumerable {
    IVanilla public vanilla;
    string public currentBaseURI;

    event NewBaseURI(string baseURI);

    constructor(
        address newVanilla,
        string memory newBaseURI,
        string memory name,
        string memory symbol
    ) ERC721(name, symbol) {
        require(newVanilla != address(0), "Vanilla: zero address");
        vanilla = IVanilla(newVanilla);

        currentBaseURI = newBaseURI;
    }

    function mint(address account, uint tokenId) external {
        require(vanilla.minters(msg.sender), "Vanilla: minter");
        ITicket ticket = ITicket(vanilla.ticket());
        if(msg.sender != address(ticket)) {
            ticket.setPendingTokenIds(tokenId);
        }
        _safeMint(account, tokenId);
    }

    function setBaseURI(string calldata newBaseURI) external {
        require(msg.sender == vanilla.admin(), "Vanilla: admin");
        currentBaseURI = newBaseURI;
        emit NewBaseURI(currentBaseURI);
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return currentBaseURI;
    }
}