// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title SmoothingILMath
/// @notice Pure helpers for full-range constant-product Impermanent Loss (IL)
/// and discrete path-exact Loss-Versus-Rebalancing (LVR), used by the
/// smoothing IL/yield proof layer.
///
/// Spec: docs/plans/2026-05-30-il-lvr-yield-variance-model.md §3, §4.1, §4.2.
///
/// Conventions:
/// - All prices are token1 per token0 in WAD (1e18) fixed point.
/// - Reserves (x = token0, y = token1) are in raw token units (no WAD scaling
///   applied by this library; whatever scale is passed in is preserved).
/// - Returned absolute values are in token1 raw units; fractions are signed
///   WAD (`-2e17` = `-20%`).
///
/// Numeraire: token1, matching the model doc. Pool-level aggregate LP. No fees
/// or compounding inside this layer — it measures position economics only.
library SmoothingILMath {
    uint256 internal constant WAD = 1e18;

    // ─── Impermanent Loss (closed form, constant product) ───────────────────

    /// @notice IL fraction for a full-range CP position when price moves from
    ///         P0 to P1, with `k_ratio = P1 / P0`.
    ///
    ///   IL_fraction = 2·sqrt(k_ratio) / (1 + k_ratio) − 1   (≤ 0)
    ///
    /// @param priceNowWad Current price `P1` in WAD (token1/token0 × 1e18).
    /// @param priceInitWad Initial price `P0` in WAD.
    /// @return ilFractionWad_ Signed WAD fraction. `0` at `P1==P0`, more
    ///         negative as `|log(k_ratio)|` grows. Bounded in `[-WAD, 0]`.
    function ilFractionWad(uint256 priceNowWad, uint256 priceInitWad) internal pure returns (int256 ilFractionWad_) {
        require(priceInitWad > 0, "P0=0");
        require(priceNowWad > 0, "P1=0");

        // k_ratio in WAD = P1 * WAD / P0
        uint256 kRatioWad = FullMath.mulDiv(priceNowWad, WAD, priceInitWad);

        // sqrt(k_ratio) in WAD = sqrt(kRatioWad * WAD)
        uint256 sqrtKrWad = FixedPointMathLib.sqrt(kRatioWad * WAD);

        // ratio_wad = 2·sqrt(k_ratio) · WAD / (1 + k_ratio)
        uint256 numWad = 2 * sqrtKrWad;
        uint256 denWad = WAD + kRatioWad;
        uint256 ratioWad = FullMath.mulDiv(numWad, WAD, denWad);

        // IL = ratio - 1 (in WAD); ratio ≤ 1 by AM-GM, so result ≤ 0.
        return int256(ratioWad) - int256(WAD);
    }

    /// @notice IL value in token1 raw units for the position
    ///         `(x0 token0, y0 token1)` deposited at price `P0`, when price
    ///         is now `P1`.
    ///
    ///   V_hold(P1) = x0·P1 + y0
    ///   IL_value   = IL_fraction · V_hold
    ///
    /// @return ilValue_ Signed token1 raw amount (≤ 0).
    function ilValue(uint256 x0, uint256 y0, uint256 priceNowWad, uint256 priceInitWad)
        internal
        pure
        returns (int256 ilValue_)
    {
        int256 fracWad = ilFractionWad(priceNowWad, priceInitWad);
        uint256 vHold = y0 + FullMath.mulDiv(x0, priceNowWad, WAD);
        // |frac| · vHold / WAD, then re-sign.
        uint256 absFrac = uint256(fracWad < 0 ? -fracWad : fracWad);
        uint256 magnitude = FullMath.mulDiv(absFrac, vHold, WAD);
        return fracWad < 0 ? -int256(magnitude) : int256(magnitude);
    }

    // ─── Loss-Versus-Rebalancing (discrete, path-exact) ─────────────────────

    /// @notice Per-step LVR when the external mid-price moves from `P_prev`
    ///         to `P_new` and a zero-fee arber rebalances the pool.
    ///
    ///   LVR_step = V_no_arb(P_new) − V_after(P_new)
    ///   V_no_arb(P_new) = y_prev + x_prev·P_new
    ///   V_after(P_new)  = 2·sqrt(k·P_new),  k = x_prev·y_prev
    ///
    /// Always ≥ 0 by AM-GM on `(y_prev, x_prev·P_new)`, with equality iff the
    /// pool is already at `P_new` (i.e. `P_prev == P_new` since the input
    /// reserves are taken to be in equilibrium with `P_prev = y_prev/x_prev`).
    /// `P_prev` is therefore not needed as an explicit argument; the caller
    /// passes the pre-step reserves and the new price.
    ///
    /// @param xPrev token0 reserve before the move (raw units).
    /// @param yPrev token1 reserve before the move (raw units).
    /// @param priceNewWad New mid price in WAD.
    /// @return lvr Per-step LVR in token1 raw units (≥ 0).
    function lvrStep(uint256 xPrev, uint256 yPrev, uint256 priceNewWad) internal pure returns (uint256 lvr) {
        // V_no_arb = y_prev + x_prev * P_new / WAD   (token1 raw)
        uint256 vNoArb = yPrev + FullMath.mulDiv(xPrev, priceNewWad, WAD);

        // V_after = 2·sqrt((k · P_new) / WAD), k = xPrev·yPrev. mulDiv keeps
        // the 512-bit product safe before the WAD reduction.
        uint256 kP_overWad = FullMath.mulDiv(xPrev, yPrev, WAD);
        // Now sqrt(kP_overWad · P_new) = sqrt(k · P_new / WAD), in raw units.
        uint256 sqrtTerm = FixedPointMathLib.sqrt(kP_overWad * priceNewWad);
        uint256 vAfter = 2 * sqrtTerm;

        // By AM-GM vNoArb ≥ vAfter; defensive saturation against rounding dust.
        lvr = vNoArb > vAfter ? vNoArb - vAfter : 0;
    }

    /// @notice Reserves of a full-range CP position with invariant `k` at
    ///         price `P` (WAD): `x(P) = sqrt(k/P)`, `y(P) = sqrt(k·P)`.
    ///         Useful for advancing the path between LVR steps.
    /// @param k Invariant `x·y` (raw·raw units; caller's responsibility to
    ///        avoid overflow at extreme deposits).
    /// @param priceWad Mid price in WAD.
    function reservesAt(uint256 k, uint256 priceWad) internal pure returns (uint256 x, uint256 y) {
        require(priceWad > 0, "P=0");
        // x = sqrt(k * WAD / P)   (raw token0)
        uint256 kOverP_wad = FullMath.mulDiv(k, WAD, priceWad);
        x = FixedPointMathLib.sqrt(kOverP_wad);
        // y = sqrt(k * P / WAD)   (raw token1)
        uint256 kP_overWad = FullMath.mulDiv(k, priceWad, WAD);
        y = FixedPointMathLib.sqrt(kP_overWad);
    }
}
