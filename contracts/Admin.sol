// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract Admin {
    struct Transaction {
        address to;
        uint value;
        string signature;
        bytes data;
        bool executed;
        uint numConfirmations;
    }

    uint public numConfirmationsRequired;
    address[] public admins;
    Transaction[] public transactions;
    mapping(address => bool) public isAdmin;
    mapping(uint => mapping(address => bool)) public isConfirmed;

    event SubmitTransaction(
        address indexed admin,
        uint indexed txIndex,
        address indexed to,
        uint value,
        string signature,
        bytes data
    );
    event ConfirmTransaction(address indexed admin, uint indexed txIndex);
    event RevokeConfirmation(address indexed admin, uint indexed txIndex);
    event ExecuteTransaction(address indexed admin, uint indexed txIndex);

    constructor(address[] memory _admins, uint _numConfirmationsRequired) {
        require(_admins.length > 2, "Vanilla: admins");
        require(
            _numConfirmationsRequired > 1 &&
            _numConfirmationsRequired <= _admins.length,
            "Vanilla: confirmations"
        );

        for (uint i = 0; i < _admins.length; i++) {
            address admin = _admins[i];

            require(admin != address(0), "Vanilla: admin");
            require(!isAdmin[admin], "Vanilla: unique admin");

            isAdmin[admin] = true;
            admins.push(admin);
        }

        numConfirmationsRequired = _numConfirmationsRequired;
    }

    function submitTransaction(
        address to,
        uint value,
        string calldata signature,
        bytes calldata data
    ) public {
        require(isAdmin[msg.sender], "Vanilla: not admin");

        uint txIndex = transactions.length;

        transactions.push(
            Transaction({
                to: to,
                value: value,
                data: data,
                signature: signature,
                executed: false,
                numConfirmations: 1
            })
        );
        isConfirmed[txIndex][msg.sender] = true;

        emit SubmitTransaction(
            msg.sender,
            txIndex,
            to,
            value,
            signature,
            data
        );
    }

    function confirmTransaction(uint txIndex) public {
        require(isAdmin[msg.sender], "Vanilla: not admin");
        require(txIndex < transactions.length, "Vanilla: tx does not exist");

        Transaction storage transaction = transactions[txIndex];

        require(!isConfirmed[txIndex][msg.sender], "Vanilla: tx already confirmed");

        transaction.numConfirmations += 1;
        isConfirmed[txIndex][msg.sender] = true;

        emit ConfirmTransaction(msg.sender, txIndex);
    }

    function executeTransaction(uint txIndex) public {
        require(isAdmin[msg.sender], "Vanilla: not admin");
        require(txIndex < transactions.length, "Vanilla: tx does not exist");

        Transaction storage transaction = transactions[txIndex];

        require(!transaction.executed, "Vanilla: tx already executed");
        require(
            transaction.numConfirmations >= numConfirmationsRequired,
            "Vanilla: cannot execute tx"
        );

        transaction.executed = true;

        bytes memory callData = abi.encodePacked(
            bytes4(keccak256(bytes(transaction.signature))),
            transaction.data
        );

        (bool success, ) = transaction.to.call{value: transaction.value}(callData);
        require(success, "Vanilla: tx failed");

        emit ExecuteTransaction(msg.sender, txIndex);
    }

    function revokeConfirmation(uint txIndex) public {
        require(isAdmin[msg.sender], "Vanilla: not admin");
        require(txIndex < transactions.length, "Vanilla: tx does not exist");

        Transaction storage transaction = transactions[txIndex];

        require(isConfirmed[txIndex][msg.sender], "Vanilla: tx not confirmed");

        transaction.numConfirmations -= 1;
        isConfirmed[txIndex][msg.sender] = false;

        emit RevokeConfirmation(msg.sender, txIndex);
    }

    function getAdmins() public view returns (address[] memory) {
        return admins;
    }

    function getTransactionCount() public view returns (uint) {
        return transactions.length;
    }

    function getTransaction(
        uint txIndex
    )
    public
    view
    returns (
        address to,
        uint value,
        string memory signature,
        bytes memory data,
        bool executed,
        uint numConfirmations
    )
    {
        Transaction storage transaction = transactions[txIndex];

        return (
            transaction.to,
            transaction.value,
            transaction.signature,
            transaction.data,
            transaction.executed,
            transaction.numConfirmations
        );
    }

    receive() external payable {

    }
}
