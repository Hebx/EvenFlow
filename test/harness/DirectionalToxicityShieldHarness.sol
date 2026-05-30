// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {DirectionalToxicityShield} from "../../src/DirectionalToxicityShield.sol";

contract DirectionalToxicityShieldHarness is DirectionalToxicityShield {
    constructor(IPoolManager poolManager) DirectionalToxicityShield(poolManager) {}

    function setPressure(PoolId poolId, int56 pressure) external {
        directionalStates[poolId].pressure = pressure;
    }

    function updatePressureForTest(PoolId poolId, int24 currentTick) external {
        _updatePressure(poolId, currentTick);
    }

    function validatePolicy(FeePolicy memory policy) external pure {
        _validatePolicy(policy);
    }

    function setFeePolicy(
        PoolId poolId,
        uint24 baseFee,
        uint24 minFee,
        uint24 maxFee,
        uint24 maxFeeStep,
        uint32 pressureScale,
        int24 maxPressure,
        uint32 decayFactor,
        uint32 filterWindow,
        uint32 decayWindow,
        uint128 liquidityFloor,
        int24 majorMoveThreshold
    ) external {
        feePolicies[poolId] = FeePolicy({
            baseFee: baseFee,
            minFee: minFee,
            maxFee: maxFee,
            maxFeeStep: maxFeeStep,
            pressureScale: pressureScale,
            maxPressure: maxPressure,
            decayFactor: decayFactor,
            filterWindow: filterWindow,
            decayWindow: decayWindow,
            liquidityFloor: liquidityFloor,
            majorMoveThreshold: majorMoveThreshold
        });
    }
}
