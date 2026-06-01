// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {YieldSmoothingMetric} from "./YieldSmoothingMetric.s.sol";
import {SmoothingILMath} from "./utils/SmoothingILMath.sol";

/// @title SmoothingProofReport
/// @notice Phase 3 of the smoothing IL/yield proof layer: a single scoreboard
/// that layers IL/LVR accounting (Phase 1 helpers) and coefficient-of-variation
/// onto the existing variance/conservation metric, all derived from the SAME
/// scenario step sequence so fees, variance, IL and LVR are measured on one
/// shared price path.
///
/// Spec: docs/plans/2026-05-30-smoothing-il-yield-proof-prd.md WS2, WS3, and
/// docs/plans/2026-05-30-il-lvr-yield-variance-model.md §3, §4.
///
/// Model conventions (from the model doc):
/// - Full-range constant-product reference LP, numeraire token1, P0 = 1e18.
/// - Price path P_i = P0 · 1.0001^(Σ tickMove) via Uniswap TickMath.
/// - Discrete path-exact LVR; closed-form IL at the final price.
/// - This is a model (labelled as such); the Phase-2 parity test bounds drift
///   of the capture/drip math from the deployed contract.
contract SmoothingProofReport is Script {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    /// Reference LP deposited at P0 = 1e18: x0 token0 + y0 token1.
    /// Chosen to match the swap-notional scale used in the variance scenarios.
    uint256 internal constant X0 = 1e24; // 1,000,000 token0
    uint256 internal constant Y0 = 1e24; // 1,000,000 token1
    uint256 internal constant P0_WAD = 1e18;

    struct ProofResult {
        // ── Variance / conservation (from YieldSmoothingMetric) ──
        uint256 rawTotal;
        uint256 smoothedPaidTotal;
        uint256 finalReserve;
        uint256 totalCaptured;
        uint256 totalDripped;
        uint256 rawStddev;
        uint256 smoothedStddev;
        int256 efficacyBps; // 1 - sigma_smooth/sigma_raw
        uint256 covRawBps; // sigma_raw / mean_raw, in bps
        uint256 covSmoothedBps; // sigma_smooth / mean_smooth, in bps
        // ── IL / LVR on the shared price path ──
        uint256 finalPriceWad; // P at end of path
        int256 ilFractionWad; // closed-form IL fraction at final price (<= 0)
        int256 ilValueWad; // IL in token1 units at final price (<= 0)
        uint256 lvrTotal; // summed discrete path-exact LVR (token1 units)
    }

    YieldSmoothingMetric internal metric;

    function setUp() public {
        metric = new YieldSmoothingMetric();
    }

    function run() external {
        if (address(metric) == address(0)) metric = new YieldSmoothingMetric();
        _log("burst then quiet (canonical smoothing case)", computeBurstThenQuiet());
        _log("sustained toxic trend (capture-dominant)", computeSustainedToxic());
        _log("choppy alternating flow (low-capture stress)", computeChoppy());
    }

    // ── Per-scenario computation ──────────────────────────────────────────────

    function computeBurstThenQuiet() public view returns (ProofResult memory) {
        return _compute(metric.computeBurstThenQuiet(), metric.stepsBurstThenQuiet());
    }

    function computeSustainedToxic() public view returns (ProofResult memory) {
        return _compute(metric.computeSustainedToxic(), metric.stepsSustainedToxic());
    }

    function computeChoppy() public view returns (ProofResult memory) {
        return _compute(metric.computeChoppy(), metric.stepsChoppy());
    }

    // ── Core ──────────────────────────────────────────────────────────────────

    function _compute(YieldSmoothingMetric.MetricResult memory m, YieldSmoothingMetric.Step[] memory steps)
        internal
        pure
        returns (ProofResult memory r)
    {
        // Carry over the conservation + variance figures.
        r.rawTotal = m.rawTotal;
        r.smoothedPaidTotal = m.smoothedPaidTotal;
        r.finalReserve = m.finalReserve;
        r.totalCaptured = m.totalCaptured;
        r.totalDripped = m.totalDripped;
        r.rawStddev = m.rawStddev;
        r.smoothedStddev = m.smoothedStddev;
        r.efficacyBps = m.efficacyBps;

        // CoV = sigma / mean, in bps. mean = total / n.
        uint256 n = m.rawStream.length;
        if (n > 0) {
            uint256 meanRaw = m.rawTotal / n;
            uint256 meanSmoothed = m.smoothedPaidTotal / n;
            r.covRawBps = meanRaw == 0 ? 0 : (m.rawStddev * BPS) / meanRaw;
            r.covSmoothedBps = meanSmoothed == 0 ? 0 : (m.smoothedStddev * BPS) / meanSmoothed;
        }

        // IL / LVR over the shared price path derived from the tick sequence.
        (uint256 finalPrice, uint256 lvrTotal) = _walkPath(steps);
        r.finalPriceWad = finalPrice;
        r.lvrTotal = lvrTotal;
        r.ilFractionWad = SmoothingILMath.ilFractionWad(finalPrice, P0_WAD);
        r.ilValueWad = SmoothingILMath.ilValue(X0, Y0, finalPrice, P0_WAD);
    }

    /// @dev Walk the scenario tick path, accumulating discrete path-exact LVR
    /// and returning the final price. The pool's invariant k is held constant
    /// (arber-rebalanced, zero-fee — worst-case LVR per model §6).
    function _walkPath(YieldSmoothingMetric.Step[] memory steps)
        internal
        pure
        returns (uint256 finalPriceWad, uint256 lvrTotal)
    {
        int24 cumulativeTick = 0;
        uint256 priceWad = P0_WAD;

        for (uint256 i = 0; i < steps.length; i++) {
            // Reserves in equilibrium at the OLD price, before this step's move.
            (uint256 xPrev, uint256 yPrev) = SmoothingILMath.reservesAt(_kFull(), priceWad);

            cumulativeTick += steps[i].tickMove;
            uint256 newPrice = _priceWadAtTick(cumulativeTick);

            lvrTotal += SmoothingILMath.lvrStep(xPrev, yPrev, newPrice);
            priceWad = newPrice;
        }
        finalPriceWad = priceWad;
    }

    /// @dev Full constant-product invariant k = x0·y0 (raw units).
    function _kFull() internal pure returns (uint256) {
        return X0 * Y0;
    }

    /// @dev Price in WAD at a Uniswap tick: P = 1.0001^tick.
    /// Derived from sqrtPriceX96 to reuse canonical TickMath rather than a
    /// bespoke pow. price = (sqrtP/2^96)^2, computed in two bounded mulDivs.
    function _priceWadAtTick(int24 tick) internal pure returns (uint256) {
        uint256 s = uint256(TickMath.getSqrtPriceAtTick(tick));
        uint256 priceX96 = FullMath.mulDiv(s, s, 1 << 96); // = price · 2^96
        return FullMath.mulDiv(priceX96, WAD, 1 << 96); // = price · WAD
    }

    // ── Reporting ──────────────────────────────────────────────────────────────

    function _log(string memory name, ProofResult memory r) internal pure {
        console2.log("");
        console2.log(name);
        console2.log("  raw total yield:     ", r.rawTotal);
        console2.log("  smoothed paid yield: ", r.smoothedPaidTotal);
        console2.log("  escrow still owed:   ", r.finalReserve);
        console2.log("  total captured:      ", r.totalCaptured);
        console2.log("  total dripped:       ", r.totalDripped);
        console2.log("  raw sigma:           ", r.rawStddev);
        console2.log("  smoothed sigma:      ", r.smoothedStddev);
        console2.log("  efficacy (bps):      ", r.efficacyBps);
        console2.log("  CoV raw (bps):       ", r.covRawBps);
        console2.log("  CoV smoothed (bps):  ", r.covSmoothedBps);
        console2.log("  final price (wad):   ", r.finalPriceWad);
        console2.log("  IL fraction (wad):   ", r.ilFractionWad);
        console2.log("  IL value (token1):   ", r.ilValueWad);
        console2.log("  LVR total (token1):  ", r.lvrTotal);
    }
}
