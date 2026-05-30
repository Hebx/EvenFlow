// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {AbstractCallback} from "reactive-lib/base/AbstractCallback.sol";
import {IPayable} from "reactive-lib/interfaces/IPayable.sol";

import {IDirectionalToxicityShield} from "./IDirectionalToxicityShield.sol";

/// @title ShieldReactiveExecutor
/// @notice Destination-side contract that receives authenticated callbacks from
/// the Reactive Network and forwards bounded automation actions to the
/// DirectionalToxicityShield hook on the same chain.
///
/// Trust model (each link checked on-chain):
///  1. Reactive Signer posts the callback transaction through the chain's
///     callback proxy. `AbstractPayer` records that proxy as `_SERVICE_PROVIDER`,
///     and we require `msg.sender == _SERVICE_PROVIDER` on every callback. This
///     is stronger than the bare `onlyCallbackSender` pattern, which checks only
///     the injected first argument (a public value that could otherwise be
///     spoofed by a direct caller).
///  2. The proxy injects the originating reactive contract address as the FIRST
///     argument of each callback; we require it to equal the registered
///     `controller`.
///  3. This executor is the only address wired as the hook's reactive executor,
///     so the hook itself gates the action and re-validates ALL eligibility
///     (quiet regime, cooldown, reserve). This executor never asserts pool state.
///
/// Deploy ordering: the executor and the Lasna controller have a mutual address
/// dependency. We break it with a set-once `controller`: deploy the executor
/// first (controller unset), deploy the controller on Lasna pointing at this
/// executor, then call {setController} once to lock the wiring. While unset, no
/// callback can pass authorization.
///
/// PoolKeys are registered by the owner because callbacks carry only the indexed
/// PoolId and an action selector, not the full key.
contract ShieldReactiveExecutor is AbstractCallback {
    using PoolIdLibrary for PoolKey;

    /// @notice The hook this executor drives.
    IDirectionalToxicityShield public immutable shield;

    /// @notice Deployer authorized to register pools and set the controller.
    address public immutable owner;

    /// @notice The authorized Lasna reactive contract (set once, post-deploy).
    address public controller;

    /// @notice Registered pool keys by PoolId (set by owner).
    mapping(PoolId => PoolKey) private _poolKeys;
    mapping(PoolId => bool) public registered;

    error NotOwner();
    error ControllerAlreadySet();
    error ControllerUnset();
    error ControllerZero();
    error UntrustedProxy(address caller);
    error UnauthorizedReactive(address sender, address expected);
    error PoolNotRegistered(PoolId poolId);

    event ControllerSet(address indexed controller);
    event PoolRegistered(PoolId indexed poolId);
    event DripCallbackReceived(PoolId indexed poolId);
    event PolicyModeCallbackReceived(PoolId indexed poolId, uint8 mode);

    /// @param callbackProxy_ Chain callback proxy address (payment service provider).
    /// @param shield_ The DirectionalToxicityShield hook to drive.
    /// @param owner_ Deployer allowed to register pools / set controller.
    /// @dev The AbstractCallback `callbackSender_` is left as address(0); this
    /// contract does its own (stricter) authorization via {_authCallback}.
    constructor(IPayable callbackProxy_, IDirectionalToxicityShield shield_, address owner_)
        AbstractCallback(callbackProxy_, address(0))
    {
        shield = shield_;
        owner = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Lock in the authorized Lasna controller. Callable once by owner.
    function setController(address controller_) external onlyOwner {
        if (controller != address(0)) revert ControllerAlreadySet();
        if (controller_ == address(0)) revert ControllerZero();
        controller = controller_;
        emit ControllerSet(controller_);
    }

    /// @notice Register the full PoolKey for a pool so callbacks can address it.
    function registerPool(PoolKey calldata key) external onlyOwner {
        PoolId poolId = key.toId();
        _poolKeys[poolId] = key;
        registered[poolId] = true;
        emit PoolRegistered(poolId);
    }

    function getPoolKey(PoolId poolId) external view returns (PoolKey memory) {
        return _poolKeys[poolId];
    }

    /// @notice Callback: release stranded escrow for a quiet pool.
    /// @param sender Injected reactive-contract address (authenticated).
    /// @param poolId Target pool.
    /// @dev The hook re-validates quiet/eligibility; a no-op there is harmless.
    function onQuietDrip(address sender, PoolId poolId) external {
        _authCallback(sender);
        if (!registered[poolId]) revert PoolNotRegistered(poolId);
        emit DripCallbackReceived(poolId);
        shield.triggerQuietDrip(_poolKeys[poolId]);
    }

    /// @notice Callback: switch the pool to a bounded fee-policy preset.
    /// @param sender Injected reactive-contract address (authenticated).
    /// @param poolId Target pool.
    /// @param mode Preset index (hook clamps/validates).
    function onPolicyMode(address sender, PoolId poolId, uint8 mode) external {
        _authCallback(sender);
        if (!registered[poolId]) revert PoolNotRegistered(poolId);
        emit PolicyModeCallbackReceived(poolId, mode);
        shield.applyPolicyMode(_poolKeys[poolId], mode);
    }

    /// @dev Two-factor callback auth: the transaction must come through the
    /// trusted callback proxy AND carry the registered controller as the injected
    /// first argument.
    function _authCallback(address sender) private view {
        if (msg.sender != address(_SERVICE_PROVIDER)) revert UntrustedProxy(msg.sender);
        address c = controller;
        if (c == address(0)) revert ControllerUnset();
        if (sender != c) revert UnauthorizedReactive(sender, c);
    }
}
