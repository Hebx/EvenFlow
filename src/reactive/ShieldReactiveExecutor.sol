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
///  1. Reactive Signer posts the callback through the chain's callback proxy.
///     `AbstractCallback` makes the proxy the payment service provider.
///  2. The proxy injects the originating reactive contract address as the FIRST
///     argument of each callback; `onlyCallbackSender` requires it to equal the
///     authorized reactive contract (`_CALLBACK_SENDER`).
///  3. This executor is the only address wired as the hook's reactive executor,
///     so the hook itself gates the action.
///  4. The hook RECOMPUTES all eligibility (quiet regime, cooldown, reserve);
///     this executor never asserts pool state.
///
/// PoolKeys are registered by the deployer because callbacks carry only the
/// indexed PoolId and an action selector, not the full key.
contract ShieldReactiveExecutor is AbstractCallback {
    using PoolIdLibrary for PoolKey;

    /// @notice The hook this executor drives.
    IDirectionalToxicityShield public immutable shield;

    /// @notice Deployer authorized to register pool keys.
    address public immutable owner;

    /// @notice Registered pool keys by PoolId (set by owner).
    mapping(PoolId => PoolKey) private _poolKeys;
    mapping(PoolId => bool) public registered;

    error NotOwner();
    error PoolNotRegistered(PoolId poolId);

    event PoolRegistered(PoolId indexed poolId);
    event DripCallbackReceived(PoolId indexed poolId);
    event PolicyModeCallbackReceived(PoolId indexed poolId, uint8 mode);

    /// @param callbackProxy_ Chain callback proxy address (payment service provider).
    /// @param authorizedReactive_ Reactive contract allowed to trigger callbacks.
    /// @param shield_ The DirectionalToxicityShield hook to drive.
    /// @param owner_ Deployer allowed to register pool keys.
    constructor(
        IPayable callbackProxy_,
        address authorizedReactive_,
        IDirectionalToxicityShield shield_,
        address owner_
    ) AbstractCallback(callbackProxy_, authorizedReactive_) {
        shield = shield_;
        owner = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
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
    function onQuietDrip(address sender, PoolId poolId) external onlyCallbackSender(sender) {
        if (!registered[poolId]) revert PoolNotRegistered(poolId);
        emit DripCallbackReceived(poolId);
        shield.triggerQuietDrip(_poolKeys[poolId]);
    }

    /// @notice Callback: switch the pool to a bounded fee-policy preset.
    /// @param sender Injected reactive-contract address (authenticated).
    /// @param poolId Target pool.
    /// @param mode Preset index (hook clamps/validates).
    function onPolicyMode(address sender, PoolId poolId, uint8 mode) external onlyCallbackSender(sender) {
        if (!registered[poolId]) revert PoolNotRegistered(poolId);
        emit PolicyModeCallbackReceived(poolId, mode);
        shield.applyPolicyMode(_poolKeys[poolId], mode);
    }
}
