// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {YieldSmoothingMetric} from "../script/YieldSmoothingMetric.s.sol";

/// @notice Asserts the LP yield-smoothing efficacy metric and its conservation
/// invariants. This is the model-level proof that the smoothing layer reduces
/// LP yield variance without destroying yield (premium is escrowed, not lost),
/// and it pins the boundary cases honestly (sustained toxic ~ neutral; choppy
/// flow strands the reserve, which is what the Reactive CRON drip exists to fix).
contract YieldSmoothingMetricTest is Test {
    YieldSmoothingMetric private metric;

    function setUp() public {
        metric = new YieldSmoothingMetric();
    }

    /// Conservation must hold exactly in every scenario: every unit of raw fee
    /// is either paid to LPs within the horizon or still escrowed (owed to LPs).
    /// Nothing is created or destroyed by the smoothing layer.
    function _assertConservation(YieldSmoothingMetric.MetricResult memory r) private pure {
        assertEq(r.smoothedPaidTotal + r.finalReserve, r.rawTotal, "yield conserved: paid + escrow == raw total");
        assertEq(r.totalCaptured - r.totalDripped, r.finalReserve, "escrow == captured - dripped");
    }

    function test_burstThenQuiet_reducesVarianceAndConservesYield() public view {
        YieldSmoothingMetric.MetricResult memory r = metric.computeBurstThenQuiet();

        _assertConservation(r);

        // Canonical smoothing case: a toxic burst captured, then released over a
        // quiet tail. Smoothing should cut the per-step yield variance sharply.
        assertGt(r.efficacyBps, int256(5000), "burst->quiet cuts yield sigma by >50%");
        assertLt(r.smoothedStddev, r.rawStddev, "smoothed stream is flatter than raw");

        // The escrow should largely drain during the quiet tail (most premium
        // returned to LPs), leaving only a small geometric-tail residual.
        assertGt(r.totalDripped, (r.totalCaptured * 90) / 100, "most captured premium dripped back");
        assertGt(r.totalCaptured, 0, "some premium was captured during the burst");
    }

    function test_choppyFlow_strandsReserve_motivatesReactiveCron() public view {
        YieldSmoothingMetric.MetricResult memory r = metric.computeChoppy();

        _assertConservation(r);

        // Choppy alternating flow keeps pressure elevated: the pool never reaches
        // the quiet regime during a swap, so the in-swap drip path never fires.
        // Premium is captured but stranded — the exact failure mode the Reactive
        // CRON-triggered drip is designed to resolve (drip with no swap).
        assertEq(r.totalDripped, 0, "no in-swap drip fires when pool never goes quiet");
        assertGt(r.finalReserve, 0, "premium is stranded in escrow");
        assertEq(r.finalReserve, r.totalCaptured, "all captured premium remains stranded");
    }

    function test_sustainedToxic_isApproximatelyNeutral_noFreeLunch() public view {
        YieldSmoothingMetric.MetricResult memory r = metric.computeSustainedToxic();

        _assertConservation(r);

        // Honest boundary: under uniformly toxic flow there is little lumpiness
        // to smooth (the raw stream is already a high plateau), so the smoothing
        // layer is roughly neutral on variance and can be marginally negative.
        assertLt(r.efficacyBps, int256(500), "sustained toxic is not a strong variance win");
        assertGt(r.efficacyBps, int256(-1000), "sustained toxic does not materially worsen variance");
        assertGt(r.totalCaptured, 0, "premium captured under sustained toxic flow");
    }

    /// Cross-scenario sanity: the stddev/efficacy math is internally consistent
    /// (efficacy sign tracks the stddev comparison) for every scenario.
    function test_efficacySignTracksStddevComparison() public view {
        YieldSmoothingMetric.MetricResult[3] memory rs =
            [metric.computeBurstThenQuiet(), metric.computeChoppy(), metric.computeSustainedToxic()];

        for (uint256 i = 0; i < rs.length; i++) {
            YieldSmoothingMetric.MetricResult memory r = rs[i];
            if (r.smoothedStddev < r.rawStddev) {
                assertGt(r.efficacyBps, int256(0), "variance down => positive efficacy");
            } else if (r.smoothedStddev > r.rawStddev) {
                assertLt(r.efficacyBps, int256(0), "variance up => negative efficacy");
            }
        }
    }
}
