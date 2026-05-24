// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {DirectionalToxicityShieldHarness} from "./harness/DirectionalToxicityShieldHarness.sol";
import {DirectionalToxicityShield} from "../src/DirectionalToxicityShield.sol";
import {BaseTest} from "./utils/BaseTest.sol";

contract DirectionalToxicityShieldTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    Currency currency0;
    Currency currency1;

    DirectionalToxicityShieldHarness hook;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        address flags = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
                    | Hooks.AFTER_SWAP_FLAG
            ) ^ (0x4444 << 144)
        );
        deployCodeTo(
            "DirectionalToxicityShieldHarness.sol:DirectionalToxicityShieldHarness", abi.encode(poolManager), flags
        );
        hook = DirectionalToxicityShieldHarness(flags);
    }

    function test_beforeInitialize_revertsForStaticFeePool() public {
        PoolKey memory staticFeeKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(DirectionalToxicityShield.NotDynamicFee.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(staticFeeKey, Constants.SQRT_PRICE_1_1);
    }

    function test_getHookPermissions_minimalMvpPermissions() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();

        assertTrue(permissions.beforeInitialize);
        assertTrue(permissions.afterInitialize);
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
        assertFalse(permissions.beforeAddLiquidity);
        assertFalse(permissions.afterAddLiquidity);
        assertFalse(permissions.beforeRemoveLiquidity);
        assertFalse(permissions.afterRemoveLiquidity);
        assertFalse(permissions.beforeDonate);
        assertFalse(permissions.afterDonate);
        assertFalse(permissions.beforeSwapReturnDelta);
        assertFalse(permissions.afterSwapReturnDelta);
        assertFalse(permissions.afterAddLiquidityReturnDelta);
        assertFalse(permissions.afterRemoveLiquidityReturnDelta);
    }

    function test_afterInitialize_setsDefaultPolicyAndState() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();

        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        DirectionalToxicityShield.FeePolicy memory policy = hook.getFeePolicy(poolId);

        assertEq(policy.baseFee, 3000);
        assertEq(policy.minFee, 500);
        assertEq(policy.maxFee, 10000);
        assertEq(policy.maxFeeStep, 500);
        assertEq(policy.pressureScale, 10);
        assertEq(policy.maxPressure, 500);
        assertEq(policy.decayFactor, 500_000);
        assertEq(policy.filterWindow, 30);
        assertEq(policy.decayWindow, 5 minutes);
        assertEq(policy.liquidityFloor, 1e18);
        assertEq(policy.majorMoveThreshold, 5);

        DirectionalToxicityShield.DirectionalState memory state = hook.getDirectionalState(poolId);

        assertEq(state.referenceTick, 0);
        assertEq(state.lastTick, 0);
        assertEq(state.pressure, 0);
        assertEq(state.lastUpdateTime, block.timestamp);
        assertEq(state.lastFee, policy.baseFee);
        assertEq(state.regime, 0);
        assertEq(hook.getCurrentRegime(poolId), 0);
    }

    function test_previewFee_returnsBaseFeeInCalmState() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -int256(1e18), sqrtPriceLimitX96: 0});

        assertEq(hook.previewFee(dynamicFeeKey, params), 3000);
    }

    function test_previewFee_higherForPressureAlignedSwap() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);
        _disableLiquidityFloor(poolId);
        hook.setPressure(poolId, 100);

        SwapParams memory params = SwapParams({zeroForOne: false, amountSpecified: -int256(1e18), sqrtPriceLimitX96: 0});

        assertEq(hook.previewFee(dynamicFeeKey, params), 3500);
    }

    function test_previewFee_lowerForCounterPressureSwap() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);
        _disableLiquidityFloor(poolId);
        hook.setPressure(poolId, 100);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -int256(1e18), sqrtPriceLimitX96: 0});

        assertEq(hook.previewFee(dynamicFeeKey, params), 2500);
    }

    function test_previewFee_clampsToMinFee() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);
        hook.setFeePolicy(poolId, 3000, 2800, 10000, 5000, 100, 500, 500_000, 30, 5 minutes, 0, 5);
        hook.setPressure(poolId, 100);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -int256(1e18), sqrtPriceLimitX96: 0});

        assertEq(hook.previewFee(dynamicFeeKey, params), 2800);
    }

    function test_previewFee_clampsToMaxFee() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);
        hook.setFeePolicy(poolId, 3000, 500, 3200, 5000, 100, 500, 500_000, 30, 5 minutes, 0, 5);
        hook.setPressure(poolId, 100);

        SwapParams memory params = SwapParams({zeroForOne: false, amountSpecified: -int256(1e18), sqrtPriceLimitX96: 0});

        assertEq(hook.previewFee(dynamicFeeKey, params), 3200);
    }

    function test_previewFee_enforcesMaxFeeStep() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);
        _disableLiquidityFloor(poolId);
        hook.setPressure(poolId, 1000);

        SwapParams memory params = SwapParams({zeroForOne: false, amountSpecified: -int256(1e18), sqrtPriceLimitX96: 0});

        assertEq(hook.previewFee(dynamicFeeKey, params), 3500);
    }

    function test_updatePressure_ignoresMoveBelowMajorMoveThreshold() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        hook.updatePressureForTest(poolId, 4);

        DirectionalToxicityShield.DirectionalState memory state = hook.getDirectionalState(poolId);
        assertEq(state.pressure, 0);
        assertEq(state.lastTick, 4);
    }

    function test_updatePressure_addsMajorTickMove() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        hook.updatePressureForTest(poolId, 10);

        DirectionalToxicityShield.DirectionalState memory state = hook.getDirectionalState(poolId);
        assertEq(state.pressure, 10);
        assertEq(state.lastTick, 10);
    }

    function test_updatePressure_resetsAfterDecayWindow() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);
        hook.setPressure(poolId, 100);

        vm.warp(block.timestamp + 5 minutes);
        hook.updatePressureForTest(poolId, 0);

        DirectionalToxicityShield.DirectionalState memory state = hook.getDirectionalState(poolId);
        assertEq(state.pressure, 0);
        assertEq(state.lastUpdateTime, block.timestamp);
    }

    function test_previewFee_returnsBaseFeeBelowLiquidityFloor() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);
        hook.setPressure(poolId, 100);

        SwapParams memory params = SwapParams({zeroForOne: false, amountSpecified: -int256(1e18), sqrtPriceLimitX96: 0});

        assertEq(hook.previewFee(dynamicFeeKey, params), 3000);
    }

    function test_exactInAndExactOut_directionClassificationUsesZeroForOne() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);
        _disableLiquidityFloor(poolId);
        hook.setPressure(poolId, 100);

        SwapParams memory exactIn =
            SwapParams({zeroForOne: false, amountSpecified: -int256(1e18), sqrtPriceLimitX96: 0});
        SwapParams memory exactOut =
            SwapParams({zeroForOne: false, amountSpecified: int256(1e18), sqrtPriceLimitX96: 0});

        assertEq(hook.previewFee(dynamicFeeKey, exactIn), 3500);
        assertEq(hook.previewFee(dynamicFeeKey, exactOut), 3500);
    }

    function test_twoPools_keepIndependentPressureState() public {
        PoolKey memory firstKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId firstPoolId = firstKey.toId();
        poolManager.initialize(firstKey, Constants.SQRT_PRICE_1_1);
        _disableLiquidityFloor(firstPoolId);
        hook.setPressure(firstPoolId, 100);

        (Currency otherCurrency0, Currency otherCurrency1) = deployCurrencyPair();
        PoolKey memory secondKey =
            PoolKey(otherCurrency0, otherCurrency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId secondPoolId = secondKey.toId();
        poolManager.initialize(secondKey, Constants.SQRT_PRICE_1_1);
        _disableLiquidityFloor(secondPoolId);
        hook.setPressure(secondPoolId, -100);

        SwapParams memory zeroForOne =
            SwapParams({zeroForOne: true, amountSpecified: -int256(1e18), sqrtPriceLimitX96: 0});

        assertEq(hook.previewFee(firstKey, zeroForOne), 2500);
        assertEq(hook.previewFee(secondKey, zeroForOne), 3500);
    }

    function testFuzz_previewFeeWithinBounds(int56 pressure, bool zeroForOne) public {
        pressure = int56(bound(pressure, -10_000, 10_000));

        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);
        _disableLiquidityFloor(poolId);
        hook.setPressure(poolId, pressure);

        SwapParams memory params =
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(1e18), sqrtPriceLimitX96: 0});

        uint24 fee = hook.previewFee(dynamicFeeKey, params);
        assertGe(fee, 500);
        assertLe(fee, 10000);
    }

    function _disableLiquidityFloor(PoolId poolId) private {
        hook.setFeePolicy(poolId, 3000, 500, 10000, 500, 10, 500, 500_000, 30, 5 minutes, 0, 5);
    }
}
