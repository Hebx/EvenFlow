// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title SmoothingCaptureMath
/// @notice Pure mirror of the on-chain premium-capture and drip arithmetic in
/// {DirectionalToxicityShield}. Extracted so the off-chain proof/sim layer can
/// reuse the exact deployed math, and so a parity test can assert this library
/// reproduces the contract to the wei on a shared input.
///
/// Spec: docs/plans/2026-05-30-smoothing-il-yield-proof-prd.md WS1, and the
/// contract's `_beforeSwap` / `_afterSwap` / `_performDrip`.
///
/// The contract captures a fraction of the *unspecified* (output for exactIn,
/// input for exactOut) currency amount, NOT a fraction of swap notional:
///
///   premiumBps = (fee - baseFee) * 10_000 / fee           // _beforeSwap
///   captured   = absUnspecified * premiumBps / 10_000      // _afterSwap
///
/// and drips a bounded fraction of the standing reserve:
///
///   drip = reserve * dripBps / 10_000                      // _performDrip
library SmoothingCaptureMath {
    uint256 internal constant BPS = 10_000;

    /// @notice Premium fraction (in bps of the unspecified amount) skimmed from
    ///         an aligned, non-quiet swap. Mirrors `_beforeSwap`.
    /// @dev Returns 0 when `fee <= baseFee` (no capture on counter-flow / calm).
    ///      Integer truncation matches the contract exactly.
    function capturePremiumBps(uint24 fee, uint24 baseFee) internal pure returns (uint256) {
        if (fee <= baseFee) return 0;
        return (uint256(fee - baseFee) * BPS) / uint256(fee);
    }

    /// @notice Premium captured from a swap, in raw units of the unspecified
    ///         currency. Mirrors `_afterSwap`'s `feeAmount`.
    /// @param absUnspecified Absolute value of the unspecified-currency delta
    ///        (the v4 `Swap` event's amount for that currency).
    /// @param fee The applied directional fee (from `FeeOverrideApplied`).
    /// @param baseFee The pool's base fee.
    function capturedAmount(uint256 absUnspecified, uint24 fee, uint24 baseFee) internal pure returns (uint256) {
        uint256 premiumBps = capturePremiumBps(fee, baseFee);
        if (premiumBps == 0) return 0;
        return (absUnspecified * premiumBps) / BPS;
    }

    /// @notice Bounded drip released from a standing reserve. Mirrors
    ///         `_performDrip`'s per-currency `drip = reserve * dripBps / 10_000`.
    /// @dev Per-currency; call once for reserve0 and once for reserve1.
    function dripAmount(uint256 reserve, uint16 dripBps) internal pure returns (uint256) {
        return (reserve * uint256(dripBps)) / BPS;
    }
}
