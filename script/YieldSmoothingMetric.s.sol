// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

/// @title YieldSmoothingMetric
/// @notice Quantifies the core LP-experience claim of the smoothing layer:
/// capturing toxic-flow premium into an escrow and dripping it back during
/// quiet regimes lowers the *variance* of the LP fee-yield stream at an
/// (approximately) conserved total yield.
///
/// The efficacy metric is `1 - sigma_smooth / sigma_raw`, expressed in bps,
/// where sigma is the population standard deviation of the per-step LP payout
/// stream. A positive value means the smoothing layer reduced yield variance;
/// `0` means no improvement and a negative value would mean it made the stream
/// lumpier.
///
/// This is a deterministic model of the on-chain logic in
/// `DirectionalToxicityShield` (directional fee -> regime -> premium capture in
/// `afterSwap`, bounded drip to in-range LPs when quiet). It does not call the
/// hook; it reproduces the same arithmetic so the relationship can be asserted
/// in CI without a fork. All claims are model-level and labelled as such.
contract YieldSmoothingMetric is Script {
    uint256 private constant FEE_DENOMINATOR = 1_000_000;
    uint256 private constant BPS = 10_000;

    struct FeePolicy {
        uint24 baseFee;
        uint24 minFee;
        uint24 maxFee;
        uint24 maxFeeStep;
        uint32 pressureScale;
        int24 maxPressure;
        uint32 decayFactor;
        uint32 filterWindow;
        uint32 decayWindow;
        int24 majorMoveThreshold;
    }

    struct SmoothingConfig {
        uint16 dripBps; // fraction of reserve released per eligible quiet step
    }

    struct Step {
        int24 tickMove;
        bool zeroForOne;
        uint128 notional;
        uint40 elapsed;
    }

    struct DirectionalState {
        int24 referenceTick;
        int56 pressure;
        uint40 lastUpdateTime;
    }

    struct MetricResult {
        // Per-step LP payout streams (token units, 1e18 scale).
        uint256[] rawStream; // directional fee paid in full to LPs each step
        uint256[] smoothedStream; // baseFee (or discounted fee) + drip each step
        uint256 rawTotal; // sum(rawStream)
        uint256 smoothedPaidTotal; // sum(smoothedStream) actually paid within horizon
        uint256 finalReserve; // premium still escrowed at horizon end (owed to LPs)
        uint256 totalCaptured; // total premium escrowed over the run
        uint256 totalDripped; // total premium released over the run
        // Variance/stddev domain (scaled; see _stddevRatioBps for exact-int method).
        uint256 rawStddev; // population sigma of rawStream
        uint256 smoothedStddev; // population sigma of smoothedStream
        int256 efficacyBps; // 1 - sigma_smooth/sigma_raw, in bps (can be negative)
    }

    function run() external pure {
        _log("toxic burst then quiet (canonical smoothing case)", computeBurstThenQuiet());
        _log("sustained toxic trend (capture-dominant)", computeSustainedToxic());
        _log("choppy alternating flow (low-capture stress)", computeChoppy());
    }

    // ── Scenarios ──────────────────────────────────────────────────────────

    function computeBurstThenQuiet() public pure returns (MetricResult memory) {
        return _compute(_burstThenQuiet(), _defaultPolicy(), SmoothingConfig({dripBps: 2500}));
    }

    function computeSustainedToxic() public pure returns (MetricResult memory) {
        return _compute(_sustainedToxic(), _defaultPolicy(), SmoothingConfig({dripBps: 2500}));
    }

    function computeChoppy() public pure returns (MetricResult memory) {
        return _compute(_choppy(), _defaultPolicy(), SmoothingConfig({dripBps: 2500}));
    }

    // ── Core model ───────────────────────────────────────────────────────────

    function _compute(Step[] memory steps, FeePolicy memory policy, SmoothingConfig memory smoothing)
        private
        pure
        returns (MetricResult memory result)
    {
        uint256 n = steps.length;
        result.rawStream = new uint256[](n);
        result.smoothedStream = new uint256[](n);

        DirectionalState memory state;
        int24 currentTick;
        uint40 nowTime;
        uint256 reserve; // escrowed premium (single-sided abstraction, token units)

        for (uint256 i = 0; i < n; i++) {
            Step memory step = steps[i];
            nowTime += step.elapsed;

            int56 effectivePressure = _effectivePressure(state, policy, nowTime);
            uint8 regime = _regimeFor(effectivePressure, policy.maxPressure);
            uint24 fee = _shieldFee(effectivePressure, policy, step.zeroForOne);

            uint256 fullFee = _feeAmount(step.notional, fee);
            uint256 baseFee = _feeAmount(step.notional, policy.baseFee);

            // RAW: LPs receive the full directional fee immediately (lumpy).
            result.rawStream[i] = fullFee;

            // SMOOTHED: capture premium when aligned & non-quiet; otherwise LPs
            // receive the quoted fee (which may be a counter-flow discount).
            uint256 lpFeeThisStep;
            if (smoothing_enabled() && fee > policy.baseFee && regime > 0) {
                // Premium escrowed; LPs get baseFee now.
                lpFeeThisStep = baseFee;
                uint256 premium = fullFee - baseFee;
                reserve += premium;
                result.totalCaptured += premium;
            } else {
                lpFeeThisStep = fullFee;
            }

            // Drip: release a bounded slice of the reserve to in-range LPs when
            // the pool is quiet and the reserve is non-empty.
            uint256 drip;
            if (regime == 0 && reserve > 0) {
                drip = (reserve * smoothing.dripBps) / BPS;
                reserve -= drip;
                result.totalDripped += drip;
            }

            result.smoothedStream[i] = lpFeeThisStep + drip;

            // Advance pressure state for the next step.
            currentTick += step.tickMove;
            _updatePressure(state, policy, currentTick, nowTime);
        }

        result.finalReserve = reserve;
        for (uint256 i = 0; i < n; i++) {
            result.rawTotal += result.rawStream[i];
            result.smoothedPaidTotal += result.smoothedStream[i];
        }

        result.rawStddev = _stddev(result.rawStream);
        result.smoothedStddev = _stddev(result.smoothedStream);
        result.efficacyBps = _efficacyBps(result.rawStddev, result.smoothedStddev);
    }

    /// @dev Smoothing is always enabled in this metric harness (the point is to
    /// compare the smoothing-on stream against the raw pass-through stream).
    function smoothing_enabled() private pure returns (bool) {
        return true;
    }

    // ── Shield fee + pressure (mirrors DirectionalToxicityShield) ──────────────

    function _shieldFee(int56 effectivePressure, FeePolicy memory policy, bool zeroForOne)
        private
        pure
        returns (uint24)
    {
        if (effectivePressure == 0) return policy.baseFee;

        uint24 adjustment = _feeAdjustment(effectivePressure, policy);
        bool aligned = effectivePressure > 0 ? !zeroForOne : zeroForOne;
        if (aligned) return _clampFee(policy.baseFee + adjustment, policy);
        return _clampFee(policy.baseFee > adjustment ? policy.baseFee - adjustment : 0, policy);
    }

    function _updatePressure(DirectionalState memory state, FeePolicy memory policy, int24 currentTick, uint40 nowTime)
        private
        pure
    {
        int24 tickMove = currentTick - state.referenceTick;
        int56 introduced = _absTick(tickMove) < uint24(policy.majorMoveThreshold) ? int56(0) : int56(tickMove);
        int56 decayed = _effectivePressure(state, policy, nowTime);

        if (nowTime - state.lastUpdateTime >= policy.filterWindow) state.referenceTick = currentTick;

        state.pressure = _clampPressure(decayed + introduced, policy.maxPressure);
        state.lastUpdateTime = nowTime;
    }

    function _effectivePressure(DirectionalState memory state, FeePolicy memory policy, uint40 nowTime)
        private
        pure
        returns (int56)
    {
        uint40 elapsed = nowTime - state.lastUpdateTime;
        if (elapsed >= policy.decayWindow) return 0;
        if (elapsed < policy.filterWindow) return state.pressure;
        return int56((int256(state.pressure) * int256(uint256(policy.decayFactor))) / int256(uint256(FEE_DENOMINATOR)));
    }

    function _regimeFor(int56 pressure, int24 maxPressure) private pure returns (uint8) {
        uint56 abs = pressure < 0 ? uint56(-pressure) : uint56(pressure);
        if (abs == 0) return 0;
        if (abs >= uint24(maxPressure) / 2) return 2;
        return 1;
    }

    function _feeAdjustment(int56 pressure, FeePolicy memory policy) private pure returns (uint24) {
        uint56 abs = pressure < 0 ? uint56(-pressure) : uint56(pressure);
        uint256 raw = uint256(abs) * policy.pressureScale;
        return raw > policy.maxFeeStep ? policy.maxFeeStep : uint24(raw);
    }

    function _clampFee(uint24 fee, FeePolicy memory policy) private pure returns (uint24) {
        if (fee < policy.minFee) return policy.minFee;
        if (fee > policy.maxFee) return policy.maxFee;
        return fee;
    }

    function _clampPressure(int56 pressure, int24 maxPressure) private pure returns (int56) {
        int56 max = int56(maxPressure);
        if (pressure > max) return max;
        if (pressure < -max) return -max;
        return pressure;
    }

    function _feeAmount(uint128 notional, uint24 fee) private pure returns (uint256) {
        return uint256(notional) * fee / FEE_DENOMINATOR;
    }

    function _absTick(int24 t) private pure returns (uint24) {
        return t < 0 ? uint24(-t) : uint24(t);
    }

    // ── Statistics (exact integer population stddev) ──────────────────────────

    /// @dev Population standard deviation, rounded down. Uses the identity
    /// n^2 * Var = n*sum(x^2) - (sum x)^2 to stay in exact integer arithmetic,
    /// then sigma = sqrt(Var) = sqrt(n*sumSq - sum^2) / n.
    function _stddev(uint256[] memory xs) private pure returns (uint256) {
        uint256 n = xs.length;
        if (n == 0) return 0;
        uint256 sum;
        uint256 sumSq;
        for (uint256 i = 0; i < n; i++) {
            sum += xs[i];
            sumSq += xs[i] * xs[i];
        }
        // numerator = n*sumSq - sum^2  (>= 0 by Cauchy-Schwarz)
        uint256 numerator = n * sumSq - sum * sum;
        return _sqrt(numerator) / n;
    }

    /// @dev efficacy = 1 - sigma_smooth/sigma_raw, in bps. Positive => variance
    /// reduced. Computed as 10_000 - (sigma_smooth * 10_000 / sigma_raw).
    function _efficacyBps(uint256 rawStddev, uint256 smoothedStddev) private pure returns (int256) {
        if (rawStddev == 0) return 0;
        uint256 ratioBps = (smoothedStddev * BPS) / rawStddev;
        return int256(BPS) - int256(ratioBps);
    }

    /// @dev Babylonian integer square root.
    function _sqrt(uint256 x) private pure returns (uint256 z) {
        if (x == 0) return 0;
        z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    // ── Scenarios ─────────────────────────────────────────────────────────────

    /// Canonical case: a 3-swap toxic burst (aligned, pressure climbs into the
    /// elevated/toxic regime, premium captured) followed by a long quiet tail
    /// where pressure decays to zero and the escrow drips back to LPs.
    function _burstThenQuiet() private pure returns (Step[] memory steps) {
        uint256 quietTail = 12;
        steps = new Step[](3 + quietTail);
        for (uint256 i = 0; i < 3; i++) {
            steps[i] = Step({tickMove: 20, zeroForOne: false, notional: 1_000_000e18, elapsed: 12});
        }
        for (uint256 i = 0; i < quietTail; i++) {
            // No tick move + long gap so pressure decays out of every regime.
            steps[3 + i] = Step({tickMove: 0, zeroForOne: false, notional: 1_000_000e18, elapsed: 5 minutes});
        }
    }

    /// Sustained toxic trend: capture dominates, fewer quiet windows to drip in.
    /// Smoothing still helps but the escrow drains more slowly (larger residual).
    function _sustainedToxic() private pure returns (Step[] memory steps) {
        steps = new Step[](16);
        for (uint256 i = 0; i < 8; i++) {
            steps[i] = Step({tickMove: 20, zeroForOne: false, notional: 1_000_000e18, elapsed: 12});
        }
        for (uint256 i = 8; i < 16; i++) {
            steps[i] = Step({tickMove: 0, zeroForOne: false, notional: 1_000_000e18, elapsed: 5 minutes});
        }
    }

    /// Choppy alternating flow: directional pressure rarely sustains, so little
    /// premium is captured. Smoothing should be roughly neutral here (small or
    /// near-zero efficacy), which is the honest "no free lunch" boundary case.
    function _choppy() private pure returns (Step[] memory steps) {
        steps = new Step[](16);
        for (uint256 i = 0; i < 16; i++) {
            bool up = i % 2 == 0;
            steps[i] =
                Step({tickMove: up ? int24(20) : int24(-20), zeroForOne: !up, notional: 1_000_000e18, elapsed: 12});
        }
    }

    function _defaultPolicy() private pure returns (FeePolicy memory) {
        return FeePolicy({
            baseFee: 3000,
            minFee: 500,
            maxFee: 10000,
            maxFeeStep: 500,
            pressureScale: 10,
            maxPressure: 500,
            decayFactor: 500_000,
            filterWindow: 30,
            decayWindow: 5 minutes,
            majorMoveThreshold: 5
        });
    }

    function _log(string memory name, MetricResult memory r) private pure {
        console2.log("");
        console2.log(name);
        console2.log("  steps:               ", r.rawStream.length);
        console2.log("  raw total yield:     ", r.rawTotal);
        console2.log("  smoothed paid yield: ", r.smoothedPaidTotal);
        console2.log("  escrow still owed:   ", r.finalReserve);
        console2.log("  total captured:      ", r.totalCaptured);
        console2.log("  total dripped:       ", r.totalDripped);
        console2.log("  raw sigma:           ", r.rawStddev);
        console2.log("  smoothed sigma:      ", r.smoothedStddev);
        console2.log("  efficacy (bps):      ", r.efficacyBps);
    }
}
