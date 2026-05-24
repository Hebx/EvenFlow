// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

contract DirectionalToxicityShield is BaseHook {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error NotDynamicFee();

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
        uint128 liquidityFloor;
        int24 majorMoveThreshold;
    }

    struct DirectionalState {
        int24 referenceTick;
        int24 lastTick;
        int56 pressure;
        uint40 lastUpdateTime;
        uint24 lastFee;
        uint8 regime;
    }

    event PoolPolicyInitialized(PoolId indexed poolId, uint24 baseFee, uint24 minFee, uint24 maxFee);
    event FeeOverrideApplied(PoolId indexed poolId, bool zeroForOne, uint24 fee, int56 pressure, uint8 regime);
    event DirectionalPressureUpdated(PoolId indexed poolId, int24 tickMove, int56 pressure, int24 referenceTick);
    event RiskRegimeChanged(PoolId indexed poolId, uint8 oldRegime, uint8 newRegime);

    mapping(PoolId poolId => FeePolicy policy) internal feePolicies;
    mapping(PoolId poolId => DirectionalState state) internal directionalStates;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal pure override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        return BaseHook.beforeInitialize.selector;
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        FeePolicy memory policy = _defaultPolicy();

        feePolicies[poolId] = policy;
        directionalStates[poolId] = DirectionalState({
            referenceTick: tick,
            lastTick: tick,
            pressure: 0,
            lastUpdateTime: uint40(block.timestamp),
            lastFee: policy.baseFee,
            regime: 0
        });

        emit PoolPolicyInitialized(poolId, policy.baseFee, policy.minFee, policy.maxFee);

        return BaseHook.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        (uint24 fee, int56 effectivePressure) = _previewFeeAndPressure(poolId, params.zeroForOne);
        DirectionalState storage state = directionalStates[poolId];
        state.lastFee = fee;

        emit FeeOverrideApplied(
            poolId,
            params.zeroForOne,
            fee,
            effectivePressure,
            _regimeFor(effectivePressure, feePolicies[poolId].maxPressure)
        );

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        _updatePressure(poolId, currentTick);

        return (BaseHook.afterSwap.selector, 0);
    }

    function getFeePolicy(PoolId poolId) external view returns (FeePolicy memory) {
        return feePolicies[poolId];
    }

    function getDirectionalState(PoolId poolId) external view returns (DirectionalState memory) {
        return directionalStates[poolId];
    }

    function getCurrentRegime(PoolId poolId) external view returns (uint8) {
        return directionalStates[poolId].regime;
    }

    function previewFee(PoolKey calldata key, SwapParams calldata params) external view returns (uint24) {
        return _previewFee(key.toId(), params.zeroForOne);
    }

    function _previewFee(PoolId poolId, bool zeroForOne) private view returns (uint24) {
        (uint24 fee,) = _previewFeeAndPressure(poolId, zeroForOne);
        return fee;
    }

    function _previewFeeAndPressure(PoolId poolId, bool zeroForOne)
        private
        view
        returns (uint24 fee, int56 effectivePressure)
    {
        FeePolicy memory policy = feePolicies[poolId];
        DirectionalState memory state = directionalStates[poolId];

        if (policy.liquidityFloor > 0 && poolManager.getLiquidity(poolId) < policy.liquidityFloor) {
            return (_clampFee(policy.baseFee, policy), 0);
        }

        effectivePressure = _effectivePressure(state, policy);
        if (effectivePressure == 0) return (_clampFee(policy.baseFee, policy), 0);

        uint24 adjustment = _feeAdjustment(effectivePressure, policy);
        bool aligned = effectivePressure > 0 ? !zeroForOne : zeroForOne;

        if (aligned) {
            uint256 increased = uint256(policy.baseFee) + adjustment;
            fee = _clampFee(increased > type(uint24).max ? type(uint24).max : uint24(increased), policy);
        } else {
            uint24 decreased = policy.baseFee > adjustment ? policy.baseFee - adjustment : 0;
            fee = _clampFee(decreased, policy);
        }
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

    function _effectivePressure(DirectionalState memory state, FeePolicy memory policy) private view returns (int56) {
        uint40 elapsed = uint40(block.timestamp) - state.lastUpdateTime;
        if (elapsed >= policy.decayWindow) return 0;
        if (elapsed < policy.filterWindow) return state.pressure;

        return int56((int256(state.pressure) * int256(uint256(policy.decayFactor))) / int256(uint256(1_000_000)));
    }

    function _updatePressure(PoolId poolId, int24 currentTick) internal {
        FeePolicy memory policy = feePolicies[poolId];
        DirectionalState storage state = directionalStates[poolId];

        int24 tickMove = currentTick - state.referenceTick;
        int56 introducedPressure =
            _absTickMove(tickMove) < uint24(policy.majorMoveThreshold) ? int56(0) : int56(tickMove);

        uint40 nowTime = uint40(block.timestamp);
        uint40 elapsed = nowTime - state.lastUpdateTime;
        int56 decayedPressure = state.pressure;

        if (elapsed >= policy.decayWindow) {
            decayedPressure = 0;
            state.referenceTick = currentTick;
        } else if (elapsed >= policy.filterWindow) {
            decayedPressure =
                int56((int256(decayedPressure) * int256(uint256(policy.decayFactor))) / int256(uint256(1_000_000)));
            state.referenceTick = currentTick;
        }

        int56 nextPressure = _clampPressure(decayedPressure + introducedPressure, policy.maxPressure);
        uint8 oldRegime = state.regime;
        uint8 newRegime = _regimeFor(nextPressure, policy.maxPressure);

        state.lastTick = currentTick;
        state.pressure = nextPressure;
        state.lastUpdateTime = nowTime;
        state.regime = newRegime;

        emit DirectionalPressureUpdated(poolId, tickMove, nextPressure, state.referenceTick);
        if (oldRegime != newRegime) emit RiskRegimeChanged(poolId, oldRegime, newRegime);
    }

    function _clampPressure(int56 pressure, int24 maxPressure) private pure returns (int56) {
        int56 max = int56(maxPressure);
        if (pressure > max) return max;
        if (pressure < -max) return -max;
        return pressure;
    }

    function _regimeFor(int56 pressure, int24 maxPressure) private pure returns (uint8) {
        uint56 pressureAbs = pressure < 0 ? uint56(-pressure) : uint56(pressure);
        if (pressureAbs == 0) return 0;
        if (pressureAbs >= uint24(maxPressure) / 2) return 2;
        return 1;
    }

    function _absTickMove(int24 tickMove) private pure returns (uint24) {
        return tickMove < 0 ? uint24(-tickMove) : uint24(tickMove);
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
            liquidityFloor: 1e18,
            majorMoveThreshold: 5
        });
    }
}
