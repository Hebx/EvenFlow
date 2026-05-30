// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "reactive-lib-classic/abstract-base/AbstractReactive.sol";
import {IReactive} from "reactive-lib-classic/interfaces/IReactive.sol";

/// @title LegacyCallbackProbe
/// @notice Minimal CLASSIC reactive contract that, on every matching CRON tick,
/// emits Callback(destChainId, sink, gas, payload) exactly like our controller's
/// _requestDrip — but stripped of all pool/auth logic and pointed at a no-auth
/// CallbackSink on Base Sepolia. Isolates the legacy->Base Sepolia delivery path.
contract LegacyCallbackProbe is AbstractReactive {
    address public constant CRON_SYS = 0x0000000000000000000000000000000000fffFfF;
    uint64 public constant CALLBACK_GAS_LIMIT = 200000;

    uint256 public immutable cronTopic0;
    uint256 public immutable destChainId;
    address public immutable sink;

    uint256 public reactCount;
    uint256 public lastReactBlock;

    event Reacted(uint256 indexed topic0, uint256 blk);

    constructor(uint256 cronTopic0_, uint256 destChainId_, address sink_) payable {
        cronTopic0 = cronTopic0_;
        destChainId = destChainId_;
        sink = sink_;
        if (!vm) {
            service.subscribe(
                block.chainid, CRON_SYS, cronTopic0_, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
        }
    }

    /// @inheritdoc IReactive
    function react(LogRecord calldata log) external vmOnly {
        if (log.topic_0 == cronTopic0 && log._contract == CRON_SYS) {
            reactCount++;
            lastReactBlock = block.number;
            emit Reacted(log.topic_0, block.number);
            bytes memory payload = abi.encodeWithSignature("onPing(address)", address(0));
            emit Callback(destChainId, sink, CALLBACK_GAS_LIMIT, payload);
        }
    }
}
