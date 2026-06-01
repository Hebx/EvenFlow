// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {AbstractCallback} from "reactive-lib-classic/abstract-base/AbstractCallback.sol";

import {IDirectionalToxicityShield} from "./IDirectionalToxicityShield.sol";

/// @title ShieldReactiveExecutor
/// @notice Destination-side contract that receives authenticated callbacks from
/// the Reactive Network and forwards bounded automation actions to the
/// DirectionalToxicityShield hook on the same chain.
///
/// Trust model (each link checked on-chain):
///  1. The Reactive Signer posts the callback transaction through the chain's
///     callback proxy. The classic `AbstractCallback` constructor records the
///     proxy as the `vendor` and adds it to the authorized-sender ACL, so
///     `msg.sender == proxy` is enforced via `authorizedSenderOnly`.
///  2. The proxy injects the originating reactive contract's `rvm_id` (the EOA
///     that deployed the reactive contract on the Reactive Network) as the
///     FIRST argument of each callback; we require it to equal the registered
///     {controllerRvmId}. NOTE: classic-mode proxies inject the rvm_id, not the
///     reactive contract's address. Checking the contract address here would
///     reject every legitimate delivery.
///  3. This executor is the only address wired as the hook's reactive executor,
///     so the hook itself gates the action and re-validates ALL eligibility
///     (quiet regime, cooldown, reserve). This executor never asserts pool state.
///
/// Deploy ordering: the executor and the Lasna controller have a mutual address
/// dependency. We break it with a set-once {setController}: deploy the executor
/// first (controller unset), deploy the controller on Lasna pointing at this
/// executor, then call {setController} once with both the controller contract
/// address and its rvm_id (the EOA broadcaster of the Lasna deploy) to lock the
/// wiring. While unset, no callback can pass authorization.
///
/// PoolKeys are registered by the owner because callbacks carry only the indexed
/// PoolId and an action selector, not the full key.
contract ShieldReactiveExecutor is AbstractCallback {
    using PoolIdLibrary for PoolKey;

    /// @notice The hook this executor drives.
    IDirectionalToxicityShield public immutable shield;

    /// @notice Deployer authorized to register pools and set the controller.
    address public immutable owner;

    /// @notice The authorized Lasna reactive contract address (set once,
    /// post-deploy). Stored as on-chain wiring metadata; NOT used for callback
    /// authentication (the proxy injects {controllerRvmId}, not this address).
    address public controller;

    /// @notice The rvm_id of the authorized Lasna reactive contract: the EOA
    /// that deployed it on the Reactive Network. The callback proxy injects
    /// this address as the first argument of every delivered callback, and we
    /// gate authorization against it. Set once together with {controller}.
    address public controllerRvmId;

    /// @notice Registered pool keys by PoolId (set by owner).
    mapping(PoolId => PoolKey) private _poolKeys;
    mapping(PoolId => bool) public registered;

    error NotOwner();
    error ControllerAlreadySet();
    error ControllerUnset();
    error ControllerZero();
    error ControllerRvmIdZero();
    error UntrustedProxy(address caller);
    error UnauthorizedReactive(address sender, address expected);
    error PoolNotRegistered(PoolId poolId);

    event ControllerSet(address indexed controller, address indexed controllerRvmId);
    event PoolRegistered(PoolId indexed poolId);
    event DripCallbackReceived(PoolId indexed poolId);
    event PolicyModeCallbackReceived(PoolId indexed poolId, uint8 mode);

    /// @param callbackProxy_ Chain callback proxy address (e.g. 0xa6eA…A5a6 on Base Sepolia).
    /// @param shield_ The DirectionalToxicityShield hook to drive.
    /// @param owner_ Deployer allowed to register pools / set controller.
    constructor(address callbackProxy_, IDirectionalToxicityShield shield_, address owner_)
        payable
        AbstractCallback(callbackProxy_)
    {
        shield = shield_;
        owner = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Lock in the authorized Lasna controller. Callable once by owner.
    /// @param controller_ Lasna reactive-contract address (informational wiring).
    /// @param controllerRvmId_ rvm_id of the Lasna reactive contract: the EOA
    /// that deployed it on the Reactive Network. The callback proxy injects
    /// this EOA as the first arg of every callback, so this is the address
    /// {_authCallback} actually checks against.
    /// @dev We require {controllerRvmId_} explicitly even though it is often the
    /// same EOA as {owner} on test deployments — at scale the controller may be
    /// deployed from a different broadcaster than the executor.
    function setController(address controller_, address controllerRvmId_) external onlyOwner {
        if (controllerRvmId != address(0)) revert ControllerAlreadySet();
        if (controller_ == address(0)) revert ControllerZero();
        if (controllerRvmId_ == address(0)) revert ControllerRvmIdZero();
        controller = controller_;
        controllerRvmId = controllerRvmId_;
        emit ControllerSet(controller_, controllerRvmId_);
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

    /// @dev Two-factor callback auth:
    ///  1. msg.sender must be the callback proxy (enforced by classic
    ///     AbstractCallback's `authorizedSenderOnly` pattern — the proxy is the
    ///     only address in the `senders` ACL).
    ///  2. The injected first argument (`sender`) must equal the registered
    ///     {controllerRvmId} — the EOA that deployed the Lasna reactive
    ///     contract. The classic callback proxy injects rvm_id, NOT the
    ///     reactive contract address; checking against the contract address
    ///     would reject every legitimate delivery.
    function _authCallback(address sender) private view {
        // Classic AbstractCallback adds the proxy to `senders` in its ctor.
        // We check msg.sender here explicitly for a clear revert message.
        if (!senders[msg.sender]) revert UntrustedProxy(msg.sender);
        address rvmId = controllerRvmId;
        if (rvmId == address(0)) revert ControllerUnset();
        if (sender != rvmId) revert UnauthorizedReactive(sender, rvmId);
    }

    /// @notice Allow the executor to receive ETH (for callback gas funding).
    receive() external payable override {}
}
