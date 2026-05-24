// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

contract DirectionalToxicityShieldSimulation is Script {
    uint256 private constant FEE_DENOMINATOR = 1_000_000;
    address private constant DEPLOYED_CLANKER_STATIC_FEE_HOOK = 0xDd5EeaFf7BD481AD55Db083062b13a3cdf0A68CC;
    uint24 private constant OBSERVED_CLANKER_FEE = 10_000;
    uint24 private constant OBSERVED_PAIRED_FEE = 5_000;
    uint24 private constant NEZLOBIN_BASE_FEE = 3_000;
    uint24 private constant NEZLOBIN_MIN_FEE = 500;
    uint24 private constant REGIS_MAX_FEE = 50_000;
    uint24 private constant NEZLOBIN_SCALE = 1_000;
    uint24 private constant NEZLOBIN_C = 750;
    uint24 private constant JASEEMPK_INITIAL_FEE = 1_000;
    uint24 private constant JASEEMPK_NORMALIZED_STEP_PER_TICK = 10;
    uint24 private constant JASEEMPK_NORMALIZED_MAX_STEP = 500;

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

    struct DirectionalState {
        int24 referenceTick;
        int56 pressure;
        uint40 lastUpdateTime;
    }

    struct Step {
        int24 tickMove;
        bool zeroForOne;
        uint128 notional;
        uint40 elapsed;
    }

    struct ScenarioResult {
        uint256 staticFees;
        uint256 plainDirectionalFees;
        uint256 asymmetricPreviousMoveFees;
        uint256 regisNezlobinFees;
        uint256 infHookNezlobinFees;
        uint256 jaseempkThresholdFees;
        uint256 deployedFixedDirectionalFees;
        uint256 shieldFees;
        uint24 maxAsymmetricPreviousMoveFee;
        uint24 maxRegisNezlobinFee;
        uint24 maxInfHookNezlobinFee;
        uint24 maxJaseempkThresholdFee;
        uint24 maxDeployedFixedDirectionalFee;
        uint24 maxShieldFee;
        int56 finalPressure;
    }

    struct StepFees {
        uint24 plainDirectionalFee;
        uint24 asymmetricPreviousMoveFee;
        uint24 regisNezlobinFee;
        uint24 infHookNezlobinFee;
        uint24 jaseempkThresholdFee;
        uint24 deployedFixedDirectionalFee;
        uint24 shieldFee;
    }

    function run() external view {
        _logScenario("one-direction toxic flow", simulateOneDirection());
        _logScenario("alternating flow", simulateAlternating());
        _logScenario("toxic flow then quiet", simulateQuietReset());
    }

    function simulateOneDirection() public view returns (ScenarioResult memory) {
        return _simulate(_oneDirectionScenario(), _defaultPolicy());
    }

    function simulateAlternating() public view returns (ScenarioResult memory) {
        return _simulate(_alternatingScenario(), _defaultPolicy());
    }

    function simulateQuietReset() public view returns (ScenarioResult memory) {
        return _simulate(_quietResetScenario(), _defaultPolicy());
    }

    function _simulate(Step[] memory steps, FeePolicy memory policy)
        private
        view
        returns (ScenarioResult memory result)
    {
        DirectionalState memory shieldState;
        int24 currentTick;
        int24 previousTickMove;
        JdsState memory jdsState;
        uint24 infHookCurrentFee = NEZLOBIN_BASE_FEE;
        uint24 jaseempkCurrentFee = JASEEMPK_INITIAL_FEE;
        uint40 nowTime = uint40(block.timestamp);

        for (uint256 i = 0; i < steps.length; i++) {
            Step memory step = steps[i];
            nowTime += step.elapsed;

            StepFees memory fees;
            fees.shieldFee = _shieldFee(shieldState, policy, step.zeroForOne, nowTime);
            fees.plainDirectionalFee = _plainDirectionalFee(previousTickMove, policy, step.zeroForOne);
            fees.asymmetricPreviousMoveFee = _jdsAsymmetricFee(jdsState, previousTickMove, step.zeroForOne);
            fees.regisNezlobinFee = _regisNezlobinFee(previousTickMove, step.zeroForOne);
            infHookCurrentFee = _infHookNezlobinFee(previousTickMove, step.zeroForOne, infHookCurrentFee);
            fees.infHookNezlobinFee = infHookCurrentFee;
            jaseempkCurrentFee = _jaseempkThresholdFee(previousTickMove, step.zeroForOne, jaseempkCurrentFee);
            fees.jaseempkThresholdFee = jaseempkCurrentFee;
            fees.deployedFixedDirectionalFee = _deployedFixedDirectionalFee(step.zeroForOne);

            _recordStep(result, step.notional, policy.baseFee, fees);

            currentTick += step.tickMove;
            _updatePressure(shieldState, policy, currentTick, nowTime);
            previousTickMove = step.tickMove;
        }

        result.finalPressure = shieldState.pressure;
    }

    function _recordStep(ScenarioResult memory result, uint128 notional, uint24 staticFee, StepFees memory fees)
        private
        pure
    {
        result.staticFees += _feeAmount(notional, staticFee);
        result.plainDirectionalFees += _feeAmount(notional, fees.plainDirectionalFee);
        result.asymmetricPreviousMoveFees += _feeAmount(notional, fees.asymmetricPreviousMoveFee);
        result.regisNezlobinFees += _feeAmount(notional, fees.regisNezlobinFee);
        result.infHookNezlobinFees += _feeAmount(notional, fees.infHookNezlobinFee);
        result.jaseempkThresholdFees += _feeAmount(notional, fees.jaseempkThresholdFee);
        result.deployedFixedDirectionalFees += _feeAmount(notional, fees.deployedFixedDirectionalFee);
        result.shieldFees += _feeAmount(notional, fees.shieldFee);

        if (fees.asymmetricPreviousMoveFee > result.maxAsymmetricPreviousMoveFee) {
            result.maxAsymmetricPreviousMoveFee = fees.asymmetricPreviousMoveFee;
        }
        if (fees.regisNezlobinFee > result.maxRegisNezlobinFee) result.maxRegisNezlobinFee = fees.regisNezlobinFee;
        if (fees.infHookNezlobinFee > result.maxInfHookNezlobinFee) {
            result.maxInfHookNezlobinFee = fees.infHookNezlobinFee;
        }
        if (fees.jaseempkThresholdFee > result.maxJaseempkThresholdFee) {
            result.maxJaseempkThresholdFee = fees.jaseempkThresholdFee;
        }
        if (fees.deployedFixedDirectionalFee > result.maxDeployedFixedDirectionalFee) {
            result.maxDeployedFixedDirectionalFee = fees.deployedFixedDirectionalFee;
        }
        if (fees.shieldFee > result.maxShieldFee) result.maxShieldFee = fees.shieldFee;
    }

    struct JdsState {
        uint24 feeDelta;
        int8 sign;
    }

    function _shieldFee(DirectionalState memory state, FeePolicy memory policy, bool zeroForOne, uint40 nowTime)
        private
        pure
        returns (uint24)
    {
        int56 effectivePressure = _effectivePressure(state, policy, nowTime);
        if (effectivePressure == 0) return policy.baseFee;

        uint24 adjustment = _feeAdjustment(effectivePressure, policy);
        bool aligned = effectivePressure > 0 ? !zeroForOne : zeroForOne;
        if (aligned) return _clampFee(policy.baseFee + adjustment, policy);

        return _clampFee(policy.baseFee > adjustment ? policy.baseFee - adjustment : 0, policy);
    }

    function _deployedFixedDirectionalFee(bool zeroForOne) private pure returns (uint24) {
        // Models deployed Base hook 0xDd5E...68CC for an observed PoolInitialized pair:
        // clankerFee=10000, pairedFee=5000. Orientation is set so zeroForOne=false hits
        // the higher directional side in the toxic-flow scenario.
        bool clankerIsToken0 = false;
        return zeroForOne != clankerIsToken0 ? OBSERVED_PAIRED_FEE : OBSERVED_CLANKER_FEE;
    }

    function _plainDirectionalFee(int24 previousTickMove, FeePolicy memory policy, bool zeroForOne)
        private
        pure
        returns (uint24)
    {
        if (previousTickMove == 0) return policy.baseFee;

        uint24 adjustment = _feeAdjustment(int56(previousTickMove), policy);
        bool aligned = previousTickMove > 0 ? !zeroForOne : zeroForOne;
        if (aligned) return _clampFee(policy.baseFee + adjustment, policy);

        return _clampFee(policy.baseFee > adjustment ? policy.baseFee - adjustment : 0, policy);
    }

    function _jdsAsymmetricFee(JdsState memory state, int24 previousTickMove, bool zeroForOne)
        private
        pure
        returns (uint24)
    {
        // Jds-23/asymmetric-fees-hook uses prior sqrt-price movement and a 0.75 multiplier.
        // This normalized model maps the same previous-move idea onto tick movement.
        if (previousTickMove != 0) {
            state.sign = previousTickMove > 0 ? int8(1) : int8(-1);
            state.feeDelta = _sourceNezlobinDelta(_absTickMove(previousTickMove), NEZLOBIN_BASE_FEE);
        }

        if (state.sign == 0) return NEZLOBIN_BASE_FEE;

        bool premium = zeroForOne ? state.sign == -1 : state.sign == 1;
        if (premium) return NEZLOBIN_BASE_FEE + state.feeDelta;

        return NEZLOBIN_BASE_FEE > state.feeDelta ? NEZLOBIN_BASE_FEE - state.feeDelta : 0;
    }

    function _regisNezlobinFee(int24 previousTickMove, bool zeroForOne) private pure returns (uint24) {
        // RegisGraptin/Uniswap-Nezlobin-Hook uses abs(tickDelta) * 750 / 1000,
        // then skews by swap side rather than tick sign.
        if (previousTickMove == 0) return NEZLOBIN_BASE_FEE;

        uint24 deltaFee = _sourceNezlobinDelta(_absTickMove(previousTickMove), type(uint24).max);
        if (zeroForOne) {
            if (deltaFee > NEZLOBIN_BASE_FEE - NEZLOBIN_MIN_FEE) return NEZLOBIN_MIN_FEE;
            return NEZLOBIN_BASE_FEE - deltaFee;
        }

        uint256 premium = uint256(NEZLOBIN_BASE_FEE) + deltaFee;
        return premium > REGIS_MAX_FEE ? REGIS_MAX_FEE : uint24(premium);
    }

    function _infHookNezlobinFee(int24 previousTickMove, bool zeroForOne, uint24 currentFee)
        private
        pure
        returns (uint24)
    {
        // emrhncvsgl/InfHook calculates beta through integer c = 750 * base / (delta * 1000),
        // so beta is roughly 2250 for the tick sizes in these scenarios.
        uint24 tickDelta = _absTickMove(previousTickMove);
        if (tickDelta == 0) return currentFee;

        uint24 c = uint24((uint256(NEZLOBIN_C) * NEZLOBIN_BASE_FEE) / (uint256(tickDelta) * NEZLOBIN_SCALE));
        uint24 beta = c * tickDelta;

        if (!zeroForOne) return NEZLOBIN_BASE_FEE + beta;
        if (beta > NEZLOBIN_BASE_FEE) return NEZLOBIN_MIN_FEE;
        return NEZLOBIN_BASE_FEE - beta;
    }

    function _jaseempkThresholdFee(int24 previousTickMove, bool zeroForOne, uint24 currentFee)
        private
        pure
        returns (uint24)
    {
        // Jaseempk/NZ-Directional-Fee is thresholded, owner-tuned, and liquidity/oracle shaped.
        // This tick-normalized model keeps its stateful threshold direction while avoiding oracle inputs.
        if (_absTickMove(previousTickMove) < 20) return currentFee;

        uint24 cDelta = _absTickMove(previousTickMove) * JASEEMPK_NORMALIZED_STEP_PER_TICK;
        if (cDelta > JASEEMPK_NORMALIZED_MAX_STEP) cDelta = JASEEMPK_NORMALIZED_MAX_STEP;

        bool token0PricePumping = previousTickMove > 0;
        bool premium = token0PricePumping ? !zeroForOne : zeroForOne;
        if (premium) return currentFee + cDelta;

        if (cDelta >= currentFee) return 1;
        return currentFee - cDelta;
    }

    function _sourceNezlobinDelta(uint24 tickDelta, uint24 cap) private pure returns (uint24) {
        uint256 deltaFee = uint256(tickDelta) * NEZLOBIN_C / NEZLOBIN_SCALE;
        if (deltaFee > cap) return cap;
        return uint24(deltaFee);
    }

    function _updatePressure(DirectionalState memory state, FeePolicy memory policy, int24 currentTick, uint40 nowTime)
        private
        pure
    {
        int24 tickMove = currentTick - state.referenceTick;
        int56 introducedPressure =
            _absTickMove(tickMove) < uint24(policy.majorMoveThreshold) ? int56(0) : int56(tickMove);
        int56 decayedPressure = _effectivePressure(state, policy, nowTime);

        if (nowTime - state.lastUpdateTime >= policy.filterWindow) state.referenceTick = currentTick;

        state.pressure = _clampPressure(decayedPressure + introducedPressure, policy.maxPressure);
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

        return int56((int256(state.pressure) * int256(uint256(policy.decayFactor))) / int256(uint256(1_000_000)));
    }

    function _feeAdjustment(int56 pressure, FeePolicy memory policy) private pure returns (uint24) {
        uint56 pressureAbs = pressure < 0 ? uint56(-pressure) : uint56(pressure);
        uint256 rawAdjustment = uint256(pressureAbs) * policy.pressureScale;
        return rawAdjustment > policy.maxFeeStep ? policy.maxFeeStep : uint24(rawAdjustment);
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

    function _absTickMove(int24 tickMove) private pure returns (uint24) {
        return tickMove < 0 ? uint24(-tickMove) : uint24(tickMove);
    }

    function _logScenario(string memory name, ScenarioResult memory result) private pure {
        console2.log("");
        console2.log(name);
        console2.log("  deployed comparator:    ", DEPLOYED_CLANKER_STATIC_FEE_HOOK);
        console2.log("  static fees:            ", result.staticFees);
        console2.log("  plain directional fees: ", result.plainDirectionalFees);
        console2.log("  JDS asymmetric fees:    ", result.asymmetricPreviousMoveFees);
        console2.log("  Regis NZ fees:          ", result.regisNezlobinFees);
        console2.log("  InfHook NZ fees:        ", result.infHookNezlobinFees);
        console2.log("  Jaseempk NZ fees:       ", result.jaseempkThresholdFees);
        console2.log("  deployed fixed-dir fees:", result.deployedFixedDirectionalFees);
        console2.log("  shield fees:            ", result.shieldFees);
        console2.log("  max JDS fee:            ", result.maxAsymmetricPreviousMoveFee);
        console2.log("  max Regis NZ fee:       ", result.maxRegisNezlobinFee);
        console2.log("  max InfHook NZ fee:     ", result.maxInfHookNezlobinFee);
        console2.log("  max Jaseempk NZ fee:    ", result.maxJaseempkThresholdFee);
        console2.log("  max deployed fixed fee: ", result.maxDeployedFixedDirectionalFee);
        console2.log("  max shield fee:         ", result.maxShieldFee);
        console2.log("  final shield pressure:  ", int256(result.finalPressure));
    }

    function _oneDirectionScenario() private pure returns (Step[] memory steps) {
        steps = new Step[](4);
        for (uint256 i = 0; i < steps.length; i++) {
            steps[i] = Step({tickMove: 20, zeroForOne: false, notional: 1_000_000e18, elapsed: 12});
        }
    }

    function _alternatingScenario() private pure returns (Step[] memory steps) {
        steps = new Step[](4);
        steps[0] = Step({tickMove: 20, zeroForOne: false, notional: 1_000_000e18, elapsed: 12});
        steps[1] = Step({tickMove: -20, zeroForOne: true, notional: 1_000_000e18, elapsed: 12});
        steps[2] = Step({tickMove: 20, zeroForOne: false, notional: 1_000_000e18, elapsed: 12});
        steps[3] = Step({tickMove: -20, zeroForOne: true, notional: 1_000_000e18, elapsed: 12});
    }

    function _quietResetScenario() private pure returns (Step[] memory steps) {
        steps = new Step[](4);
        steps[0] = Step({tickMove: 25, zeroForOne: false, notional: 1_000_000e18, elapsed: 12});
        steps[1] = Step({tickMove: 25, zeroForOne: false, notional: 1_000_000e18, elapsed: 12});
        steps[2] = Step({tickMove: 0, zeroForOne: false, notional: 1_000_000e18, elapsed: 5 minutes});
        steps[3] = Step({tickMove: 25, zeroForOne: false, notional: 1_000_000e18, elapsed: 12});
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
}
