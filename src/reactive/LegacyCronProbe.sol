// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "reactive-lib-classic/abstract-base/AbstractReactive.sol";
import {IReactive} from "reactive-lib-classic/interfaces/IReactive.sol";

/// @title LegacyCronProbe
/// @notice Minimal CLASSIC-lib isolation probe for Reactive Lasna legacy.
/// Counts every react() invocation into on-chain state (read via eth_call,
/// since react()-emitted logs are not visible through omni/legacy getLogs).
///
/// Purpose: settle whether react() actually FIRES on legacy for a CRON
/// subscription (same mechanism as ShieldReactiveControllerLegacy), separating
/// "our subscription is wrong" (reactCount stays 0) from "Signer is not
/// delivering Callback to Base Sepolia" (reactCount climbs but no destination
/// delivery).
contract LegacyCronProbe is AbstractReactive {
    /// @notice CRON emitter on classic Lasna = the system contract 0x...fffFfF.
    address public constant CRON_SYS = 0x0000000000000000000000000000000000fffFfF;

    uint256 public immutable cronTopic0;

    uint256 public reactCount;
    uint256 public lastReactBlock;
    uint256 public lastTopic0;
    address public lastContract;

    event Reacted(uint256 indexed topic0, address indexed src, uint256 blk);

    constructor(uint256 cronTopic0_) payable {
        cronTopic0 = cronTopic0_;
        // Subscribe only on the Reactive Network side (system contract present).
        if (!vm) {
            service.subscribe(block.chainid, CRON_SYS, cronTopic0_, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
    }

    /// @inheritdoc IReactive
    function react(LogRecord calldata log) external vmOnly {
        reactCount++;
        lastReactBlock = block.number;
        lastTopic0 = log.topic_0;
        lastContract = log._contract;
        emit Reacted(log.topic_0, log._contract, block.number);
    }
}
