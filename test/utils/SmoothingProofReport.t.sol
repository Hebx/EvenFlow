// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SmoothingProofReport} from "../../script/SmoothingProofReport.s.sol";

/// @notice Phase 3 of the smoothing IL/yield proof layer: the unified
/// scoreboard. Asserts conservation as a HARD gate, CoV/efficacy consistency,
/// and that IL/LVR are computed coherently on the shared scenario price path.
///
/// Spec: docs/plans/2026-05-30-smoothing-il-yield-proof-prd.md WS2, WS3.
contract SmoothingProofReportTest is Test {
    SmoothingProofReport private report;

    function setUp() public {
        report = new SmoothingProofReport();
        report.setUp();
    }

    // ── Conservation hard gate (WS3) ────────────────────────────────────────

    /// Every unit of raw fee is either paid within the horizon or still escrowed
    /// (owed to LPs). The smoothing layer neither creates nor destroys yield.
    function _assertConservation(SmoothingProofReport.ProofResult memory r) private pure {
        assertEq(r.smoothedPaidTotal + r.finalReserve, r.rawTotal, "paid + escrow == raw total");
        assertEq(r.totalCaptured - r.totalDripped, r.finalReserve, "escrow == captured - dripped");
    }

    function test_conservation_holdsInEveryScenario() public {
        _assertConservation(report.computeBurstThenQuiet());
        _assertConservation(report.computeSustainedToxic());
        _assertConservation(report.computeChoppy());
    }

    // ── Variance / CoV consistency (WS3) ────────────────────────────────────

    function test_burstThenQuiet_cutsVarianceAndCoV() public {
        SmoothingProofReport.ProofResult memory r = report.computeBurstThenQuiet();
        _assertConservation(r);

        // Canonical case: smoothing flattens the per-step yield stream.
        assertGt(r.efficacyBps, int256(5000), "burst->quiet cuts sigma by >50%");
        assertLt(r.smoothedStddev, r.rawStddev, "smoothed sigma below raw");
        assertLt(r.covSmoothedBps, r.covRawBps, "smoothed CoV below raw CoV");
    }

    /// CoV sign must agree with the stddev comparison in every scenario (the
    /// means are positive, so CoV ordering tracks sigma ordering only when means
    /// are comparable; here we assert the within-scenario raw vs smoothed sign).
    function test_covTracksStddevWithinScenario() public {
        SmoothingProofReport.ProofResult[3] memory rs =
            [report.computeBurstThenQuiet(), report.computeChoppy(), report.computeSustainedToxic()];
        for (uint256 i = 0; i < rs.length; i++) {
            SmoothingProofReport.ProofResult memory r = rs[i];
            if (r.smoothedStddev < r.rawStddev) {
                assertGt(r.efficacyBps, int256(0), "sigma down => positive efficacy");
            } else if (r.smoothedStddev > r.rawStddev) {
                assertLt(r.efficacyBps, int256(0), "sigma up => negative efficacy");
            }
        }
    }

    // ── IL / LVR coherence on the shared path (WS2) ─────────────────────────

    /// A one-directional toxic burst moves price up, so IL must be strictly
    /// negative and LVR strictly positive on that path.
    function test_burstThenQuiet_hasNegativeILAndPositiveLVR() public {
        SmoothingProofReport.ProofResult memory r = report.computeBurstThenQuiet();
        assertGt(r.finalPriceWad, 1e18, "one-directional burst raises price");
        assertLt(r.ilFractionWad, int256(0), "directional move => IL < 0");
        assertLt(r.ilValueWad, int256(0), "IL value < 0");
        assertGt(r.lvrTotal, 0, "price moved => LVR > 0");
    }

    /// Sustained toxic moves price further than the short burst, so its IL and
    /// LVR magnitudes must both be larger (monotonic in path displacement).
    function test_sustainedToxic_hasLargerILAndLVRThanBurst() public {
        SmoothingProofReport.ProofResult memory burst = report.computeBurstThenQuiet();
        SmoothingProofReport.ProofResult memory sustained = report.computeSustainedToxic();

        assertGt(sustained.finalPriceWad, burst.finalPriceWad, "sustained moves price further");
        // IL is negative; larger displacement => more negative.
        assertLt(sustained.ilFractionWad, burst.ilFractionWad, "sustained IL more negative");
        assertGt(sustained.lvrTotal, burst.lvrTotal, "sustained LVR larger");
    }

    /// Choppy flow ends roughly where it started (alternating ticks), so net IL
    /// is near zero, but LVR is strictly positive because the arber profits on
    /// every oscillation regardless of net displacement. This is the headline
    /// distinction between IL (path-independent) and LVR (path-dependent).
    function test_choppy_nearZeroILButStrictlyPositiveLVR() public {
        SmoothingProofReport.ProofResult memory r = report.computeChoppy();

        // Even number of alternating +20/-20 ticks returns to ~P0.
        assertApproxEqAbs(r.finalPriceWad, 1e18, 1e15, "choppy path returns near P0");
        // IL essentially nil at the round-trip endpoint.
        assertApproxEqAbs(r.ilFractionWad, int256(0), 1e13, "round-trip IL ~ 0");
        // But LVR accrues on every swing — the cost of rebalancing a round trip.
        assertGt(r.lvrTotal, 0, "round-trip still bleeds LVR");
    }

    /// IL (endpoint, path-independent) and LVR (cumulative, path-dependent) are
    /// both material on the sustained monotonic path. We deliberately do NOT
    /// assert one dominates the other: with N equal steps, endpoint IL scales
    /// with (total move)^2 while the coarse discrete LVR sum scales with
    /// (total move)^2 / N, so endpoint IL here is ~N x the discrete LVR sum.
    /// The discrete LVR is a documented lower bound on the continuous
    /// rebalancing cost (model doc: finer steps -> larger LVR). We pin both as
    /// strictly positive and non-trivial relative to the position value.
    function test_sustainedToxic_ilAndLvrAreBothMaterial() public {
        SmoothingProofReport.ProofResult memory r = report.computeSustainedToxic();
        uint256 ilMagnitude = uint256(-r.ilValueWad);

        assertGt(ilMagnitude, 0, "endpoint IL is material");
        assertGt(r.lvrTotal, 0, "cumulative LVR is material");

        // Both should be a non-trivial fraction of a wei-dust floor on a ~2e24
        // position (sanity that neither collapsed to rounding noise).
        assertGt(ilMagnitude, 1e12, "IL above dust floor");
        assertGt(r.lvrTotal, 1e12, "LVR above dust floor");
    }
}
