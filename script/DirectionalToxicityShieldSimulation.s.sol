// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

contract DirectionalToxicityShieldSimulation is Script {
    uint256 private constant FEE_DENOMINATOR = 1_000_000;
    address private constant DEPLOYED_CLANKER_STATIC_FEE_HOOK = 0xDd5EeaFf7BD481AD55Db083062b13a3cdf0A68CC;
    uint24 private constant OBSERVED_CLANKER_FEE = 10_000;
    uint24 private constant OBSERVED_PAIRED_FEE = 5_000;

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
        uint256 deployedFixedDirectionalFees;
        uint256 shieldFees;
        uint24 maxDeployedFixedDirectionalFee;
        uint24 maxShieldFee;
        int56 finalPressure;
    }

    function run() external view {
        FeePolicy memory policy = _defaultPolicy();

        _logScenario("one-direction toxic flow", _simulate(_oneDirectionScenario(), policy));
        _logScenario("alternating flow", _simulate(_alternatingScenario(), policy));
        _logScenario("toxic flow then quiet", _simulate(_quietResetScenario(), policy));
    }

    function _simulate(Step[] memory steps, FeePolicy memory policy)
        private
        view
        returns (ScenarioResult memory result)
    {
        DirectionalState memory shieldState;
        int24 currentTick;
        int24 previousTickMove;
        uint40 nowTime = uint40(block.timestamp);

        for (uint256 i = 0; i < steps.length; i++) {
            Step memory step = steps[i];
            nowTime += step.elapsed;

            uint24 shieldFee = _shieldFee(shieldState, policy, step.zeroForOne, nowTime);
            uint24 plainFee = _plainDirectionalFee(previousTickMove, policy, step.zeroForOne);
            uint24 deployedFixedDirectionalFee = _deployedFixedDirectionalFee(step.zeroForOne);

            result.staticFees += _feeAmount(step.notional, policy.baseFee);
            result.plainDirectionalFees += _feeAmount(step.notional, plainFee);
            result.deployedFixedDirectionalFees += _feeAmount(step.notional, deployedFixedDirectionalFee);
            result.shieldFees += _feeAmount(step.notional, shieldFee);
            if (deployedFixedDirectionalFee > result.maxDeployedFixedDirectionalFee) {
                result.maxDeployedFixedDirectionalFee = deployedFixedDirectionalFee;
            }
            if (shieldFee > result.maxShieldFee) result.maxShieldFee = shieldFee;

            currentTick += step.tickMove;
            _updatePressure(shieldState, policy, currentTick, nowTime);
            previousTickMove = step.tickMove;
        }

        result.finalPressure = shieldState.pressure;
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
        console2.log("  deployed fixed-dir fees:", result.deployedFixedDirectionalFees);
        console2.log("  shield fees:            ", result.shieldFees);
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
