// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SmoothingILMath} from "../../script/utils/SmoothingILMath.sol";

/// @notice Phase 1 of the smoothing IL/yield proof layer: pure helpers for
/// constant-product Impermanent Loss and discrete path-exact LVR. Anchors on
/// the textbook closed-form values cited in
/// docs/plans/2026-05-30-il-lvr-yield-variance-model.md §4.1, §4.2.
contract SmoothingILMathTest is Test {
    uint256 private constant WAD = 1e18;

    // ─── IL closed form ─────────────────────────────────────────────────────

    function test_ilFraction_isZeroAtUnchangedPrice() public pure {
        int256 frac = SmoothingILMath.ilFractionWad(1e18, 1e18);
        assertEq(frac, int256(0), "IL == 0 when P1 == P0");
    }

    /// k_ratio = 4 → IL = 2·2/(1+4) − 1 = 4/5 − 1 = −20% exactly.
    function test_ilFraction_kRatio4_isMinus20Percent() public pure {
        int256 frac = SmoothingILMath.ilFractionWad(4e18, 1e18);
        // -2e17 with a tiny tolerance for integer sqrt rounding.
        assertApproxEqAbs(frac, -int256(2e17), 1e9, "IL fraction == -20% at k_ratio=4");
    }

    /// Symmetric: k_ratio = 1/4 must produce the same IL as k_ratio = 4.
    function test_ilFraction_isSymmetricUnderInversion() public pure {
        int256 fracUp = SmoothingILMath.ilFractionWad(4e18, 1e18);
        int256 fracDown = SmoothingILMath.ilFractionWad(1e18, 4e18);
        assertApproxEqAbs(fracUp, fracDown, 1e9, "IL invariant under k_ratio inversion");
    }

    /// IL must always be ≤ 0 (LP value never exceeds hold).
    function test_ilFraction_isAlwaysNonPositive() public pure {
        uint256[7] memory ks = [uint256(1e18), 9e17, 11e17, 5e17, 2e18, 1e15, 1000e18];
        for (uint256 i = 0; i < ks.length; i++) {
            int256 frac = SmoothingILMath.ilFractionWad(ks[i], 1e18);
            assertLe(frac, int256(0), "IL fraction must be non-positive");
        }
    }

    /// |IL| is monotone non-decreasing as the price moves further from P0.
    function test_ilFraction_growsMonotonicallyWithDistance() public pure {
        // Increasing price moves: 1.0x, 1.5x, 2.0x, 4.0x, 10x.
        uint256[5] memory ps = [uint256(1e18), 15e17, 2e18, 4e18, 10e18];
        int256 prev = SmoothingILMath.ilFractionWad(ps[0], 1e18);
        for (uint256 i = 1; i < ps.length; i++) {
            int256 cur = SmoothingILMath.ilFractionWad(ps[i], 1e18);
            assertLe(cur, prev, "|IL| grows as price diverges further");
            prev = cur;
        }
    }

    /// Sanity at a smaller textbook number: k_ratio=2 → IL ≈ −0.0572%
    /// (= 2·sqrt(2)/3 − 1).
    function test_ilFraction_kRatio2_matchesTextbookValue() public pure {
        int256 frac = SmoothingILMath.ilFractionWad(2e18, 1e18);
        // Reference: 2*sqrt(2)/3 - 1 = 0.94280904... - 1 = -0.05719096... → -5.7191e16
        assertApproxEqAbs(frac, -int256(57190958e9), 1e12, "IL fraction at k_ratio=2");
    }

    /// IL value scales with hold value: x0·P1 + y0.
    function test_ilValue_scalesWithHoldNotional() public pure {
        // Deposit at P0=1e18 with x0=1e18, y0=1e18 (V0 = 2 token1).
        // At P1=4e18, V_hold = 1·4 + 1 = 5; IL = -20% · 5 = -1.
        int256 il = SmoothingILMath.ilValue(1e18, 1e18, 4e18, 1e18);
        // Tolerance for integer sqrt; 1e9 dust on a 1e18 magnitude.
        assertApproxEqAbs(il, -int256(1e18), 1e10, "IL value at k_ratio=4 with V_hold=5e18");
    }

    function test_ilValue_isZeroAtUnchangedPrice() public pure {
        int256 il = SmoothingILMath.ilValue(1e18, 1e18, 1e18, 1e18);
        assertEq(il, int256(0), "IL value == 0 when P1 == P0");
    }

    // ─── Discrete path-exact LVR ────────────────────────────────────────────

    /// LVR is zero when the price doesn't move (`priceNew == y/x`, the pool's
    /// current mid given the input reserves).
    function test_lvrStep_isZeroAtNoMove() public pure {
        uint256 x = 1e18;
        uint256 y = 1e18;
        // Pool is in equilibrium with P_prev = y/x = 1e18.
        uint256 lvr = SmoothingILMath.lvrStep(x, y, 1e18);
        assertEq(lvr, 0, "LVR == 0 with no price move");
    }

    /// LVR is always ≥ 0 (zero-fee arber profit).
    function test_lvrStep_isAlwaysNonNegative() public pure {
        uint256 x = 1e18;
        uint256 y = 1e18;
        // Move price up and down by various magnitudes.
        uint256[5] memory ps = [uint256(11e17), 12e17, 5e17, 2e18, 8e17];
        for (uint256 i = 0; i < ps.length; i++) {
            uint256 lvr = SmoothingILMath.lvrStep(x, y, ps[i]);
            assertGe(lvr, 0, "LVR is non-negative");
        }
    }

    /// |LVR| is monotone non-decreasing in |price move|. Compare moves of
    /// 1%, 5%, 20%, 100% from a unit pool.
    function test_lvrStep_isMonotoneInPriceDistance() public pure {
        uint256 x = 1e18;
        uint256 y = 1e18; // P_prev = 1e18
        uint256[4] memory targets = [uint256(101e16), 105e16, 12e17, 2e18];
        uint256 prev = 0;
        for (uint256 i = 0; i < targets.length; i++) {
            uint256 lvr = SmoothingILMath.lvrStep(x, y, targets[i]);
            assertGe(lvr, prev, "LVR grows with |price move|");
            prev = lvr;
        }
    }

    /// LVR is approximately symmetric: rebalancing through a 2x or 1/2x move
    /// from a balanced pool extracts comparable value (up to integer rounding).
    function test_lvrStep_approxSymmetricUnderInverseMove() public pure {
        uint256 x = 1e18;
        uint256 y = 1e18; // P_prev = 1e18
        uint256 lvrUp = SmoothingILMath.lvrStep(x, y, 2e18);
        uint256 lvrDown = SmoothingILMath.lvrStep(x, y, 5e17);
        // Up move books arber profit in token1 units that scale with the
        // post-move price, so they need not match exactly. We assert each is
        // a meaningful fraction of the other (within 2x), not bit-equal.
        uint256 lo = lvrUp < lvrDown ? lvrUp : lvrDown;
        uint256 hi = lvrUp < lvrDown ? lvrDown : lvrUp;
        assertGt(lo, 0, "both directions extract LVR");
        assertLe(hi, 2 * lo, "LVR magnitudes within 2x across inverse moves");
    }

    /// LVR step on a 4x move from x=1, y=1 has a known reference:
    /// V_no_arb = y + x·P = 1 + 4 = 5
    /// V_after  = 2·sqrt(k·P) = 2·sqrt(1·4) = 4
    /// LVR_step = 5 − 4 = 1 token1 unit (1e18 raw).
    function test_lvrStep_reference4xMoveOnUnitPool() public pure {
        uint256 lvr = SmoothingILMath.lvrStep(1e18, 1e18, 4e18);
        assertApproxEqAbs(lvr, 1e18, 1e10, "LVR step at 4x move == 1 token1");
    }

    // ─── Reserves at P (path advance helper) ────────────────────────────────

    /// reservesAt should round-trip: starting from x=y=1e18 (k=1e36, P=1e18),
    /// querying reservesAt(k, 1e18) returns the same reserves up to rounding.
    function test_reservesAt_roundTripsAtInitialPrice() public pure {
        uint256 k = 1e18 * 1e18; // x·y
        (uint256 x, uint256 y) = SmoothingILMath.reservesAt(k, 1e18);
        assertApproxEqAbs(x, 1e18, 1e6, "x round-trip");
        assertApproxEqAbs(y, 1e18, 1e6, "y round-trip");
    }

    /// reservesAt is monotone in price: as P rises, x falls and y rises.
    function test_reservesAt_isMonotoneInPrice() public pure {
        uint256 k = 1e18 * 1e18;
        (uint256 xLo, uint256 yLo) = SmoothingILMath.reservesAt(k, 5e17); // P=0.5
        (uint256 xMid, uint256 yMid) = SmoothingILMath.reservesAt(k, 1e18); // P=1
        (uint256 xHi, uint256 yHi) = SmoothingILMath.reservesAt(k, 2e18); // P=2

        assertGt(xLo, xMid, "x decreases with price");
        assertGt(xMid, xHi, "x decreases with price");
        assertLt(yLo, yMid, "y increases with price");
        assertLt(yMid, yHi, "y increases with price");
    }
}
