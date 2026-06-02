// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {AbstractReactive} from "reactive-lib-classic/abstract-base/AbstractReactive.sol";

/// @title ShieldReactiveController
/// @notice Reactive Smart Contract (lives on Reactive Lasna legacy, chain 5318007)
/// that automates the DirectionalToxicityShield smoothing layer.
///
/// It solves the stranded-reserve problem: the in-swap drip only fires if a swap
/// happens during a quiet regime, so a genuinely idle pool (no swaps at all)
/// would never release its escrowed premium even though time decay has made it
/// quiet. This controller gives the pool a decentralized clock:
///  - subscribes to the hook's `RiskRegimeChanged` (fast reaction when a swap
///    flips a pool to quiet), and
///  - subscribes to the Reactive CRON event to sweep idle pools that emit no
///    events at all (the actually-stranded case).
/// On either trigger it emits a `Callback` event targeting the destination
/// executor, which the Reactive Signer delivers cross-chain. The hook
/// re-validates everything; a callback for a pool that is not actually eligible
/// is a cheap no-op.
///
/// @dev Built against `reactive-lib-classic` (system contract at
/// `0x0000000000000000000000000000000000fffFfF`, RPC `lasna-rpc.rnk.dev`).
/// Callbacks are requested by emitting the inherited `Callback` event — the
/// canonical legacy mechanism. The CRON topic0 and CRON system-contract address
/// are constructor parameters (network params supplied at deploy time).
contract ShieldReactiveController is AbstractReactive {
    // ─── Constants ───────────────────────────────────────────────────────────────

    /// @notice topic0 of DirectionalToxicityShield.RiskRegimeChanged(bytes32,uint8,uint8).
    /// Verified: cast keccak "RiskRegimeChanged(bytes32,uint8,uint8)".
    uint256 public constant RISK_REGIME_CHANGED_TOPIC0 =
        0xb8a947857cc396ba992936587c4bfebf37908e930241b80287b6f5a612963ed8;

    /// @notice Quiet regime value emitted by the hook (regime 0 = calm/quiet).
    uint256 private constant REGIME_QUIET = 0;

    /// @notice Gas limit for the cross-chain callback delivery.
    uint64 private constant CALLBACK_GAS_LIMIT = 1_000_000;

    /// @dev Reason codes for the emitted QuietDripRequested event.
    uint256 private constant REASON_REGIME_QUIET = 1;
    uint256 private constant REASON_CRON = 2;

    // ─── Immutables ──────────────────────────────────────────────────────────────

    /// @notice Origin chain id where the hook is deployed (e.g. 84532 Base Sepolia).
    uint256 public immutable originChainId;

    /// @notice The hook (event source) on the origin chain.
    address public immutable shieldHook;

    /// @notice Destination chain id where the executor lives.
    uint256 public immutable destinationChainId;

    /// @notice The destination executor contract.
    address public immutable executor;

    /// @notice Target pool (the demo pool). Stored so CRON sweeps can address it.
    PoolId public immutable targetPool;

    /// @notice CRON system-contract address that emits cron events.
    /// On classic Lasna this is the system contract itself (`0x…fffFfF`).
    address public immutable cronSystem;

    /// @notice topic0 of the subscribed CRON event (cadence-specific network param).
    uint256 public immutable cronTopic0;

    // ─── Events ──────────────────────────────────────────────────────────────────

    event QuietDripRequested(bytes32 indexed poolId, uint256 reason);

    error ZeroAddress();

    // ─── Constructor ─────────────────────────────────────────────────────────────

    /// @param originChainId_ Chain id of the hook (origin).
    /// @param shieldHook_ Hook address (origin event source).
    /// @param destinationChainId_ Chain id of the executor (destination).
    /// @param executor_ Destination executor address.
    /// @param targetPool_ PoolId to sweep on CRON.
    /// @param cronSystem_ CRON system-contract address (classic: 0x…fffFfF).
    /// @param cronTopic0_ topic0 of the CRON cadence to subscribe to.
    constructor(
        uint256 originChainId_,
        address shieldHook_,
        uint256 destinationChainId_,
        address executor_,
        PoolId targetPool_,
        address cronSystem_,
        uint256 cronTopic0_
    ) payable {
        if (shieldHook_ == address(0) || executor_ == address(0) || cronSystem_ == address(0)) {
            revert ZeroAddress();
        }
        originChainId = originChainId_;
        shieldHook = shieldHook_;
        destinationChainId = destinationChainId_;
        executor = executor_;
        targetPool = targetPool_;
        cronSystem = cronSystem_;
        cronTopic0 = cronTopic0_;

        // Subscriptions only exist on the top-level Reactive Network, not inside
        // the ReactVM (where the system contract is absent). `vm` is set by
        // AbstractReactive.detectVm() in its constructor (runs before this body).
        if (!vm) {
            // Hook's RiskRegimeChanged on the origin chain.
            service.subscribe(
                originChainId_,
                shieldHook_,
                RISK_REGIME_CHANGED_TOPIC0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );

            // CRON for idle-pool sweeps. CRON is emitted on the Reactive Network
            // itself (block.chainid here) by the cron system contract.
            service.subscribe(
                block.chainid, cronSystem_, cronTopic0_, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
        }
    }

    // ─── IReactive ───────────────────────────────────────────────────────────────

    /// @notice Entry point for handling new event notifications.
    function react(LogRecord calldata log) external vmOnly {
        if (log.topic_0 == RISK_REGIME_CHANGED_TOPIC0 && log._contract == shieldHook) {
            // RiskRegimeChanged(poolId indexed, uint8 oldRegime, uint8 newRegime).
            // poolId = topic_1; (oldRegime, newRegime) ABI-encoded in data.
            (, uint256 newRegime) = abi.decode(log.data, (uint256, uint256));
            if (newRegime == REGIME_QUIET) {
                _requestDrip(PoolId.wrap(bytes32(log.topic_1)), REASON_REGIME_QUIET);
            }
        } else if (log.topic_0 == cronTopic0 && log._contract == cronSystem) {
            // Periodic sweep of the configured target pool. The hook re-checks
            // eligibility, so an ineligible pool is a cheap no-op.
            _requestDrip(targetPool, REASON_CRON);
        }
    }

    // ─── Internal ────────────────────────────────────────────────────────────────

    /// @dev Request the destination callback via the canonical legacy mechanism:
    /// emit the inherited `Callback` event. The Reactive Signer picks it up and
    /// delivers it cross-chain through the destination callback proxy.
    ///
    /// The first argument of the callback payload is reserved for the reactive
    /// contract address, which the callback proxy injects for authentication; we
    /// pass address(0) as a placeholder.
    function _requestDrip(PoolId poolId, uint256 reason) internal {
        emit QuietDripRequested(PoolId.unwrap(poolId), reason);

        bytes memory payload =
            abi.encodeWithSignature("onQuietDrip(address,bytes32)", address(0), PoolId.unwrap(poolId));

        emit Callback(destinationChainId, executor, CALLBACK_GAS_LIMIT, payload);
    }
}
