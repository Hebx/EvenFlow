// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IDirectionalToxicityShield
/// @notice Minimal interface for the Reactive executor to drive bounded
/// automation actions on the deployed hook. Mirrors the executor-gated
/// entrypoints; intentionally narrow so the executor surface stays small.
interface IDirectionalToxicityShield {
    /// @notice Release a bounded slice of escrowed premium to in-range LPs when
    /// the pool is in a quiet regime. The hook recomputes all eligibility.
    function triggerQuietDrip(PoolKey calldata key) external;

    /// @notice Switch the pool's fee policy among pre-approved bounded presets.
    function applyPolicyMode(PoolKey calldata key, uint8 mode) external;
}
