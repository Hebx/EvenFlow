// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

contract DirectionalToxicityShieldBacktest is Script {
    uint256 private constant FEE_DENOMINATOR = 1_000_000;
    uint24 private constant BASE_FEE = 3_000;
    uint24 private constant MIN_FEE = 500;
    uint24 private constant MAX_FEE = 10_000;
    uint24 private constant SHIELD_MAX_STEP = 500;
    uint32 private constant SHIELD_PRESSURE_SCALE = 10;
    int24 private constant SHIELD_MAX_PRESSURE = 500;
    uint32 private constant SHIELD_DECAY_FACTOR = 500_000;
    uint32 private constant SHIELD_FILTER_WINDOW = 30;
    uint32 private constant SHIELD_DECAY_WINDOW = 5 minutes;
    int24 private constant MAJOR_MOVE_THRESHOLD = 5;
    uint24 private constant NEZLOBIN_C = 750;
    uint24 private constant NEZLOBIN_SCALE = 1_000;

    struct ReplayStep {
        int24 tickMove;
        bool zeroForOne;
        uint128 notional;
        uint128 activeLiquidity;
        uint40 elapsed;
        uint24 volatilityBps;
        uint24 oracleDislocationBps;
    }

    struct DirectionalState {
        int24 referenceTick;
        int56 pressure;
        uint40 lastUpdateTime;
    }

    struct JdsState {
        uint24 feeDelta;
        int8 sign;
    }

    struct AntiToxicityState {
        int56 imbalance;
    }

    struct VpinState {
        int256 imbalance;
        uint256 volume;
        int8 direction;
    }

    struct BacktestResult {
        uint256 staticFees;
        uint256 jdsAsymmetricFees;
        uint256 antiToxicityFees;
        uint256 dynamicAmmFees;
        uint256 detoxOracleFees;
        uint256 vpinFees;
        uint256 shieldFees;
        uint24 jdsMaxFee;
        uint24 antiToxicityMaxFee;
        uint24 dynamicAmmMaxFee;
        uint24 detoxOracleMaxFee;
        uint24 vpinMaxFee;
        uint24 shieldMaxFee;
        uint24 jdsLastFee;
        uint24 shieldLastFee;
        int56 shieldFinalPressure;
    }

    struct RuntimeState {
        DirectionalState shield;
        JdsState jds;
        AntiToxicityState antiToxicity;
        VpinState vpin;
        int24 currentTick;
        int24 previousTickMove;
        uint40 nowTime;
    }

    struct StepFees {
        uint24 jds;
        uint24 antiToxicity;
        uint24 dynamicAmm;
        uint24 detoxOracle;
        uint24 vpin;
        uint24 shield;
    }

    function run() external pure {
        _log("adverse trend", backtestAdverseTrend());
        _log("mean reversion", backtestMeanReversion());
        _log("quiet after toxic", backtestQuietAfterToxic());
    }

    function backtestAdverseTrend() public pure returns (BacktestResult memory) {
        return _backtest(_adverseTrendReplay());
    }

    function backtestMeanReversion() public pure returns (BacktestResult memory) {
        return _backtest(_meanReversionReplay());
    }

    function backtestQuietAfterToxic() public pure returns (BacktestResult memory) {
        return _backtest(_quietAfterToxicReplay());
    }

    function _backtest(ReplayStep[] memory steps) private pure returns (BacktestResult memory result) {
        RuntimeState memory state;

        for (uint256 i = 0; i < steps.length; i++) {
            ReplayStep memory step = steps[i];
            state.nowTime += step.elapsed;

            StepFees memory fees = _previewFees(state, step);
            _recordStep(result, step.notional, fees);

            state.currentTick += step.tickMove;
            _updateShieldPressure(state.shield, state.currentTick, state.nowTime);
            _updateJds(state.jds, step.tickMove);
            _updateAntiToxicity(state.antiToxicity, step.tickMove);
            _updateVpin(state.vpin, step);
            state.previousTickMove = step.tickMove;
        }

        result.shieldFinalPressure = state.shield.pressure;
    }

    function _previewFees(RuntimeState memory state, ReplayStep memory step)
        private
        pure
        returns (StepFees memory fees)
    {
        fees.shield = _shieldFee(state.shield, step.zeroForOne, state.nowTime);
        fees.jds = _jdsAsymmetricFee(state.jds, step.zeroForOne);
        fees.antiToxicity = _antiToxicityFee(state.antiToxicity, step);
        fees.dynamicAmm = _dynamicAmmFee(step);
        fees.detoxOracle = _detoxOracleFee(step);
        fees.vpin = _vpinFee(state.vpin, step.zeroForOne);
    }

    function _recordStep(BacktestResult memory result, uint128 notional, StepFees memory fees) private pure {
        result.staticFees += _feeAmount(notional, BASE_FEE);
        result.jdsAsymmetricFees += _feeAmount(notional, fees.jds);
        result.antiToxicityFees += _feeAmount(notional, fees.antiToxicity);
        result.dynamicAmmFees += _feeAmount(notional, fees.dynamicAmm);
        result.detoxOracleFees += _feeAmount(notional, fees.detoxOracle);
        result.vpinFees += _feeAmount(notional, fees.vpin);
        result.shieldFees += _feeAmount(notional, fees.shield);

        if (fees.jds > result.jdsMaxFee) result.jdsMaxFee = fees.jds;
        if (fees.antiToxicity > result.antiToxicityMaxFee) result.antiToxicityMaxFee = fees.antiToxicity;
        if (fees.dynamicAmm > result.dynamicAmmMaxFee) result.dynamicAmmMaxFee = fees.dynamicAmm;
        if (fees.detoxOracle > result.detoxOracleMaxFee) result.detoxOracleMaxFee = fees.detoxOracle;
        if (fees.vpin > result.vpinMaxFee) result.vpinMaxFee = fees.vpin;
        if (fees.shield > result.shieldMaxFee) result.shieldMaxFee = fees.shield;
        result.jdsLastFee = fees.jds;
        result.shieldLastFee = fees.shield;
    }

    function _shieldFee(DirectionalState memory state, bool zeroForOne, uint40 nowTime) private pure returns (uint24) {
        int56 effectivePressure = _effectiveShieldPressure(state, nowTime);
        if (effectivePressure == 0) return BASE_FEE;

        uint24 adjustment = _shieldAdjustment(effectivePressure);
        bool aligned = effectivePressure > 0 ? !zeroForOne : zeroForOne;
        if (aligned) return _clampFee(BASE_FEE + adjustment);

        return _clampFee(BASE_FEE > adjustment ? BASE_FEE - adjustment : 0);
    }

    function _jdsAsymmetricFee(JdsState memory state, bool zeroForOne) private pure returns (uint24) {
        if (state.sign == 0) return BASE_FEE;

        bool premium = zeroForOne ? state.sign == -1 : state.sign == 1;
        if (premium) return BASE_FEE + state.feeDelta;

        return BASE_FEE > state.feeDelta ? BASE_FEE - state.feeDelta : 0;
    }

    function _antiToxicityFee(AntiToxicityState memory state, ReplayStep memory step) private pure returns (uint24) {
        if (state.imbalance == 0) return BASE_FEE;

        bool aligned = state.imbalance > 0 ? !step.zeroForOne : step.zeroForOne;
        uint24 adjustment = _antiToxicityAdjustment(state, step);
        if (aligned) return _clampFee(BASE_FEE + adjustment);

        return _clampFee(BASE_FEE > adjustment ? BASE_FEE - adjustment : 0);
    }

    function _dynamicAmmFee(ReplayStep memory step) private pure returns (uint24) {
        uint256 sizePremium = uint256(step.notional) * 1_500 / uint256(step.activeLiquidity);
        uint256 volatilityPremium = uint256(step.volatilityBps) * 20;
        return _clampFee(BASE_FEE + uint24(sizePremium + volatilityPremium));
    }

    function _detoxOracleFee(ReplayStep memory step) private pure returns (uint24) {
        if (step.oracleDislocationBps == 0) return BASE_FEE;

        uint256 capturedArbFee = uint256(step.oracleDislocationBps) * 70;
        return _clampFee(BASE_FEE + uint24(capturedArbFee));
    }

    function _vpinFee(VpinState memory state, bool zeroForOne) private pure returns (uint24) {
        if (state.volume == 0) return BASE_FEE;

        uint256 imbalance = state.imbalance < 0 ? uint256(-state.imbalance) : uint256(state.imbalance);
        uint256 vpin = imbalance * 1e18 / state.volume;
        if (vpin > 1e18) vpin = 1e18;

        uint256 toxicityFee = BASE_FEE + (uint256(MAX_FEE - BASE_FEE) * vpin / 1e18);
        bool aligned = state.direction > 0 ? !zeroForOne : zeroForOne;
        if (!aligned && toxicityFee > 250) toxicityFee -= 250;
        if (aligned) toxicityFee += 250;

        return _clampFee(uint24(toxicityFee));
    }

    function _updateShieldPressure(DirectionalState memory state, int24 currentTick, uint40 nowTime) private pure {
        int24 tickMove = currentTick - state.referenceTick;
        int56 introducedPressure = _absTickMove(tickMove) < uint24(MAJOR_MOVE_THRESHOLD) ? int56(0) : int56(tickMove);
        int56 decayedPressure = _effectiveShieldPressure(state, nowTime);

        if (nowTime - state.lastUpdateTime >= SHIELD_FILTER_WINDOW) state.referenceTick = currentTick;

        state.pressure = _clampPressure(decayedPressure + introducedPressure, SHIELD_MAX_PRESSURE);
        state.lastUpdateTime = nowTime;
    }

    function _updateJds(JdsState memory state, int24 tickMove) private pure {
        if (tickMove == 0) return;

        state.sign = tickMove > 0 ? int8(1) : int8(-1);
        state.feeDelta = _sourceNezlobinDelta(_absTickMove(tickMove), BASE_FEE);
    }

    function _updateAntiToxicity(AntiToxicityState memory state, int24 tickMove) private pure {
        if (_absTickMove(tickMove) < uint24(MAJOR_MOVE_THRESHOLD)) return;

        int56 move = int56(tickMove);
        if ((state.imbalance > 0 && move < 0) || (state.imbalance < 0 && move > 0)) {
            state.imbalance = move;
        } else {
            state.imbalance = _clampPressure(state.imbalance + move, SHIELD_MAX_PRESSURE);
        }
    }

    function _updateVpin(VpinState memory state, ReplayStep memory step) private pure {
        int256 signedVolume = step.zeroForOne ? -int256(uint256(step.notional)) : int256(uint256(step.notional));
        state.imbalance += signedVolume;
        state.volume += step.notional;
        state.direction = state.imbalance > 0 ? int8(1) : int8(-1);
    }

    function _effectiveShieldPressure(DirectionalState memory state, uint40 nowTime) private pure returns (int56) {
        uint40 elapsed = nowTime - state.lastUpdateTime;
        if (elapsed >= SHIELD_DECAY_WINDOW) return 0;
        if (elapsed < SHIELD_FILTER_WINDOW) return state.pressure;

        return int56((int256(state.pressure) * int256(uint256(SHIELD_DECAY_FACTOR))) / int256(uint256(1_000_000)));
    }

    function _shieldAdjustment(int56 pressure) private pure returns (uint24) {
        uint56 pressureAbs = pressure < 0 ? uint56(-pressure) : uint56(pressure);
        uint256 rawAdjustment = uint256(pressureAbs) * SHIELD_PRESSURE_SCALE;
        return rawAdjustment > SHIELD_MAX_STEP ? SHIELD_MAX_STEP : uint24(rawAdjustment);
    }

    function _antiToxicityAdjustment(AntiToxicityState memory state, ReplayStep memory step)
        private
        pure
        returns (uint24)
    {
        uint56 imbalanceAbs = state.imbalance < 0 ? uint56(-state.imbalance) : uint56(state.imbalance);
        uint256 historyAdjustment = uint256(imbalanceAbs) * 12;
        uint256 sizeAdjustment = uint256(step.notional) * 1_000 / uint256(step.activeLiquidity);
        uint256 adjustment = historyAdjustment + sizeAdjustment;
        return adjustment > 2_000 ? 2_000 : uint24(adjustment);
    }

    function _sourceNezlobinDelta(uint24 tickDelta, uint24 cap) private pure returns (uint24) {
        uint256 deltaFee = uint256(tickDelta) * NEZLOBIN_C / NEZLOBIN_SCALE;
        if (deltaFee > cap) return cap;
        return uint24(deltaFee);
    }

    function _feeAmount(uint128 notional, uint24 fee) private pure returns (uint256) {
        return uint256(notional) * fee / FEE_DENOMINATOR;
    }

    function _clampFee(uint256 fee) private pure returns (uint24) {
        if (fee < MIN_FEE) return MIN_FEE;
        if (fee > MAX_FEE) return MAX_FEE;
        return uint24(fee);
    }

    function _clampPressure(int56 pressure, int24 maxPressure) private pure returns (int56) {
        int56 max = int56(maxPressure);
        if (pressure > max) return max;
        if (pressure < -max) return -max;
        return pressure;
    }

    function _absTickMove(int24 tickMove) private pure returns (uint24) {
        return tickMove < 0 ? uint24(-tickMove) : uint24(tickMove);
    }

    function _log(string memory name, BacktestResult memory result) private pure {
        console2.log("");
        console2.log(name);
        console2.log("  static fees:       ", result.staticFees);
        console2.log("  JDS asymmetric:    ", result.jdsAsymmetricFees);
        console2.log("  anti-toxicity:     ", result.antiToxicityFees);
        console2.log("  dynamic AMM:       ", result.dynamicAmmFees);
        console2.log("  detox oracle:      ", result.detoxOracleFees);
        console2.log("  VPIN:              ", result.vpinFees);
        console2.log("  shield:            ", result.shieldFees);
        console2.log("  max shield fee:    ", result.shieldMaxFee);
        console2.log("  final pressure:    ", int256(result.shieldFinalPressure));
    }

    function _adverseTrendReplay() private pure returns (ReplayStep[] memory steps) {
        steps = new ReplayStep[](6);
        for (uint256 i = 0; i < steps.length; i++) {
            steps[i] = ReplayStep({
                tickMove: 24,
                zeroForOne: false,
                notional: 1_000_000e18,
                activeLiquidity: 50_000_000e18,
                elapsed: 12,
                volatilityBps: 70,
                oracleDislocationBps: 80
            });
        }
    }

    function _meanReversionReplay() private pure returns (ReplayStep[] memory steps) {
        steps = new ReplayStep[](6);
        steps[0] = ReplayStep(24, false, 1_000_000e18, 50_000_000e18, 12, 70, 0);
        steps[1] = ReplayStep(-18, true, 1_000_000e18, 50_000_000e18, 12, 65, 0);
        steps[2] = ReplayStep(16, false, 1_000_000e18, 50_000_000e18, 12, 60, 0);
        steps[3] = ReplayStep(-20, true, 1_000_000e18, 50_000_000e18, 12, 55, 0);
        steps[4] = ReplayStep(12, false, 1_000_000e18, 50_000_000e18, 12, 50, 0);
        steps[5] = ReplayStep(-14, true, 1_000_000e18, 50_000_000e18, 12, 45, 0);
    }

    function _quietAfterToxicReplay() private pure returns (ReplayStep[] memory steps) {
        steps = new ReplayStep[](5);
        steps[0] = ReplayStep(28, false, 1_000_000e18, 50_000_000e18, 12, 75, 70);
        steps[1] = ReplayStep(28, false, 1_000_000e18, 50_000_000e18, 12, 75, 70);
        steps[2] = ReplayStep(0, false, 1_000_000e18, 50_000_000e18, 5 minutes, 30, 0);
        steps[3] = ReplayStep(0, false, 1_000_000e18, 50_000_000e18, 5 minutes, 25, 0);
        steps[4] = ReplayStep(12, false, 1_000_000e18, 50_000_000e18, 12, 35, 0);
    }
}
