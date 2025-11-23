// SPDX-License-Identifier: MIT

pragma solidity ^0.8.22;

import { OApp, MessagingFee, Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { OAppOptionsType3 } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OAppOptionsType3.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title BatchSendMock contract for demonstrating multiple outbound cross-chain calls using LayerZero.
 * @notice THIS IS AN EXAMPLE CONTRACT. DO NOT USE THIS CODE IN PRODUCTION.
 * @dev This contract showcases how to send multiple cross-chain calls with one source function call using LayerZero's OApp Standard.
 */
contract MyOApp is OApp, OAppOptionsType3 {
    /// @notice Last received message data.
    string public data = "Nothing received yet";

    /// @notice Message types that are used to identify the various OApp operations.
    /// @dev These values are used in things like combineOptions() in OAppOptionsType3 (enforcedOptions).
    uint16 public constant SEND = 1;

    /// @notice Emitted when a message is received from another chain.
    event MessageReceived(string message, uint32 senderEid, bytes32 sender);

    /// @notice Emitted when a message is sent to another chain (A -> B).
    event MessageSent(string message, uint32 dstEid);

    /// @dev Revert with this error when an invalid message type is used.
    error InvalidMsgType();

    /**
     * @dev Constructs a new BatchSend contract instance.
     * @param _endpoint The LayerZero endpoint for this contract to interact with.
     * @param _owner The owner address that will be set as the owner of the contract.
     */
    constructor(address _endpoint, address _owner) OApp(_endpoint, _owner) Ownable(msg.sender) {}

    // Override to change fee check from equivalency to < since batch fees are cumulative
    function _payNative(uint256 _nativeFee) internal override returns (uint256 nativeFee) {
        if (msg.value < _nativeFee) revert NotEnoughNative(msg.value);
        return _nativeFee;
    }

    /**
     * @notice Returns the estimated messaging fee for a given message.
     * @param _dstEids Destination endpoint ID array where the message will be batch sent.
     * @param _msgType The type of message being sent.
     * @param _message The message content.
     * @param _extraSendOptions Extra gas options for receiving the send call (A -> B).
     * Will be summed with enforcedOptions, even if no enforcedOptions are set.
     * @param _payInLzToken Boolean flag indicating whether to pay in LZ token.
     * @return totalFee The estimated messaging fee for sending to all pathways.
     */
    function quote(
        uint32[] memory _dstEids,
        uint16 _msgType,
        string memory _message, // Semantic naming for message content
        bytes calldata _extraSendOptions,
        bool _payInLzToken
    ) public view returns (MessagingFee memory totalFee) {
        bytes memory encodedMessage = abi.encode(_message); // Clear distinction: input vs processed

        for (uint i = 0; i < _dstEids.length; i++) {
            bytes memory options = combineOptions(_dstEids[i], _msgType, _extraSendOptions);
            MessagingFee memory fee = _quote(_dstEids[i], encodedMessage, options, _payInLzToken);
            totalFee.nativeFee += fee.nativeFee;
            totalFee.lzTokenFee += fee.lzTokenFee;
        }
    }

    function send(
        uint32[] memory _dstEids,
        uint16 _msgType,
        string memory _message,
        bytes calldata _extraSendOptions // gas settings for A -> B
    ) external payable {
        // Message type validation for security and extensibility
        if (_msgType != SEND) {
            revert InvalidMsgType();
        }

        // Gas efficiency: calculate total fees upfront (fail-fast pattern)
        MessagingFee memory totalFee = quote(_dstEids, _msgType, _message, _extraSendOptions, false);
        require(msg.value >= totalFee.nativeFee, "Insufficient fee provided");

        // Encodes the message before invoking _lzSend.
        bytes memory _encodedMessage = abi.encode(_message);

        uint256 totalNativeFeeUsed = 0;
        uint256 remainingValue = msg.value;

        for (uint i = 0; i < _dstEids.length; i++) {
            bytes memory options = combineOptions(_dstEids[i], _msgType, _extraSendOptions);
            MessagingFee memory fee = _quote(_dstEids[i], _encodedMessage, options, false);

            totalNativeFeeUsed += fee.nativeFee;
            remainingValue -= fee.nativeFee;

            // Granular fee tracking per destination
            require(remainingValue >= 0, "Insufficient fee for this destination");

            _lzSend(
                _dstEids[i],
                _encodedMessage,
                options,
                fee,
                payable(msg.sender)
            );

            emit MessageSent(_message, _dstEids[i]); // Event emission for tracking
        }
    }

    /**
     * @notice Internal function to handle receiving messages from another chain.
     * @dev Decodes and processes the received message based on its type.
     * @param _origin Data about the origin of the received message.
     * @param message The received message content.
     */
    function _lzReceive(
        Origin calldata _origin,
        bytes32 /*guid*/,
        bytes calldata message,
        address, // Executor address as specified by the OApp.
        bytes calldata // Any extra data or options to trigger on receipt.
    ) internal override {
        string memory _data = abi.decode(message, (string));
        data = _data;

        emit MessageReceived(data, _origin.srcEid, _origin.sender);
    }
}