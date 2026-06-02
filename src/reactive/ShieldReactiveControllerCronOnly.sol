// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {AbstractReactive} from "reactive-lib-classic/abstract-base/AbstractReactive.sol";

/// @title ShieldReactiveControllerCronOnly
/// @notice Single-subscription variant of {ShieldReactiveController}. Subscribes
/// ONLY to the Reactive CRON event on the Reactive Network and, on each tick,
/// emits a cross-chain {Callback} requesting an `onQuietDrip` on the destination
/// executor.
///
/// Why this exists: a previously-deployed full controller (regime + cron) works
/// per ReactVM accounting, but redeploying that exact subscription tuple from
/// the same deployer EOA was rejected by the legacy system contract on Lasna
/// with the catch-all `Failure` revert (the cron-only pattern, identical to
/// what LegacyCallbackProbe uses, is known to deploy cleanly). This contract
/// gives us a clean live-demo path for the rvm_id auth fix without touching
/// the regime-event subscription path.
///
/// Cadence: chosen at deploy time via `cronTopic0` (e.g. Cron10, Cron100). The
/// hook re-validates eligibility, so a callback for a currently-non-quiet pool
/// is a cheap no-op on the destination side.
contract ShieldReactiveControllerCronOnly is AbstractReactive {
    /// @notice Gas limit for the cross-chain callback delivery.
    uint64 private constant CALLBACK_GAS_LIMIT = 1_000_000;

    /// @dev Reason code for the QuietDripRequested event (cron sweep).
    uint256 private constant REASON_CRON = 2;

    /// @notice Destination chain id where the executor lives.
    uint256 public immutable destinationChainId;

    /// @notice The destination executor contract.
    address public immutable executor;

    /// @notice Target pool. Single pool by design (one-pool live demo).
    PoolId public immutable targetPool;

    /// @notice CRON system-contract address that emits cron events.
    /// On classic Lasna this is the system contract itself (`0x…fffFfF`).
    address public immutable cronSystem;

    /// @notice topic0 of the subscribed CRON event (cadence-specific network param).
    uint256 public immutable cronTopic0;

    event QuietDripRequested(bytes32 indexed poolId, uint256 reason);

    error ZeroAddress();

    constructor(
        uint256 destinationChainId_,
        address executor_,
        PoolId targetPool_,
        address cronSystem_,
        uint256 cronTopic0_
    ) payable {
        if (executor_ == address(0) || cronSystem_ == address(0)) revert ZeroAddress();
        destinationChainId = destinationChainId_;
        executor = executor_;
        targetPool = targetPool_;
        cronSystem = cronSystem_;
        cronTopic0 = cronTopic0_;

        if (!vm) {
            // Subscribe ONLY to CRON. Identical pattern to LegacyCallbackProbe.
            service.subscribe(
                block.chainid, cronSystem_, cronTopic0_, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
        }
    }

    /// @notice Entry point for handling new event notifications.
    function react(LogRecord calldata log) external vmOnly {
        if (log.topic_0 == cronTopic0 && log._contract == cronSystem) {
            emit QuietDripRequested(PoolId.unwrap(targetPool), REASON_CRON);

            bytes memory payload =
                abi.encodeWithSignature("onQuietDrip(address,bytes32)", address(0), PoolId.unwrap(targetPool));
            emit Callback(destinationChainId, executor, CALLBACK_GAS_LIMIT, payload);
        }
    }
}
