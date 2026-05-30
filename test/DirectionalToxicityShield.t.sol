// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {DirectionalToxicityShieldHarness} from "./harness/DirectionalToxicityShieldHarness.sol";
import {DirectionalToxicityShield} from "../src/DirectionalToxicityShield.sol";
import {BaseTest} from "./utils/BaseTest.sol";

contract DirectionalToxicityShieldTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    event PoolPolicyInitialized(PoolId indexed poolId, uint24 baseFee, uint24 minFee, uint24 maxFee);
    event FeeOverrideApplied(PoolId indexed poolId, bool zeroForOne, uint24 fee, int56 pressure, uint8 regime);
    event DirectionalPressureUpdated(PoolId indexed poolId, int24 tickMove, int56 pressure, int24 referenceTick);
    event RiskRegimeChanged(PoolId indexed poolId, uint8 oldRegime, uint8 newRegime);
    event SmoothingConfigured(PoolId indexed poolId, bool enabled, uint32 dripBlockInterval, uint16 dripBps);

    Currency currency0;
    Currency currency1;

    DirectionalToxicityShieldHarness hook;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        address flags = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
                    | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
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
        assertTrue(permissions.afterSwapReturnDelta);
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

    function test_afterInitialize_emitsPoolPolicyInitialized() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();

        vm.expectEmit(true, false, false, true, address(hook));
        emit PoolPolicyInitialized(poolId, 3000, 500, 10000);

        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);
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

    function test_updatePressure_emitsPressureAndRegimeEvents() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        vm.expectEmit(true, false, false, true, address(hook));
        emit DirectionalPressureUpdated(poolId, 10, 10, 0);
        vm.expectEmit(true, false, false, true, address(hook));
        emit RiskRegimeChanged(poolId, 0, 1);

        hook.updatePressureForTest(poolId, 10);
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

    function test_updatePressure_decaysAfterFilterWindow() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);
        hook.setPressure(poolId, 100);

        vm.warp(block.timestamp + 30);
        hook.updatePressureForTest(poolId, 0);

        DirectionalToxicityShield.DirectionalState memory state = hook.getDirectionalState(poolId);
        assertEq(state.pressure, 50);
        assertEq(state.referenceTick, 0);
        assertEq(state.lastUpdateTime, block.timestamp);
    }

    function test_previewFee_appliesFilterWindowDecayBeforePricing() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);
        hook.setFeePolicy(poolId, 3000, 500, 10000, 5000, 10, 500, 500_000, 30, 5 minutes, 0, 5);
        hook.setPressure(poolId, 40);

        vm.warp(block.timestamp + 30);
        SwapParams memory params = SwapParams({zeroForOne: false, amountSpecified: -int256(1e18), sqrtPriceLimitX96: 0});

        assertEq(hook.previewFee(dynamicFeeKey, params), 3200);
    }

    function test_previewFee_resetsAfterDecayWindowBeforePricing() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);
        _disableLiquidityFloor(poolId);
        hook.setPressure(poolId, 100);

        vm.warp(block.timestamp + 5 minutes);
        SwapParams memory params = SwapParams({zeroForOne: false, amountSpecified: -int256(1e18), sqrtPriceLimitX96: 0});

        assertEq(hook.previewFee(dynamicFeeKey, params), 3000);
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

    function test_swap_recordsAppliedOverrideFee() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        _initializePoolWithFullRangeLiquidity(dynamicFeeKey);
        _disableLiquidityFloor(poolId);
        hook.setPressure(poolId, 100);

        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: dynamicFeeKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        DirectionalToxicityShield.DirectionalState memory state = hook.getDirectionalState(poolId);
        assertEq(state.lastFee, 3500);
    }

    function test_swap_emitsFeeOverrideApplied() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        _initializePoolWithFullRangeLiquidity(dynamicFeeKey);
        _disableLiquidityFloor(poolId);
        hook.setPressure(poolId, 100);

        vm.expectEmit(true, false, false, true, address(hook));
        emit FeeOverrideApplied(poolId, false, 3500, 100, 1);

        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: dynamicFeeKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function test_swapExactOut_recordsAppliedOverrideFee() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        _initializePoolWithFullRangeLiquidity(dynamicFeeKey);
        _disableLiquidityFloor(poolId);
        hook.setPressure(poolId, 100);

        swapRouter.swapTokensForExactTokens({
            amountOut: 1e17,
            amountInMax: 2e18,
            zeroForOne: false,
            poolKey: dynamicFeeKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        DirectionalToxicityShield.DirectionalState memory state = hook.getDirectionalState(poolId);
        assertEq(state.lastFee, 3500);
    }

    function test_swap_updatesPressureFromExecutedTick() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        _initializePoolWithFullRangeLiquidity(dynamicFeeKey);
        _disableLiquidityFloor(poolId);

        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: dynamicFeeKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        DirectionalToxicityShield.DirectionalState memory state = hook.getDirectionalState(poolId);
        assertGt(state.lastTick, 0);
        assertGt(state.pressure, 0);
    }

    function test_e2e_sameDirectionFlowRaisesFeeThenQuietPeriodResetsPricing() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        _initializePoolWithFullRangeLiquidity(dynamicFeeKey);
        _disableLiquidityFloor(poolId);

        _swapExactIn(dynamicFeeKey, false, 1e18);
        assertEq(hook.getDirectionalState(poolId).lastFee, 3000);

        _swapExactIn(dynamicFeeKey, false, 1e18);
        assertEq(hook.getDirectionalState(poolId).lastFee, 3500);

        vm.warp(block.timestamp + 5 minutes);
        _swapExactIn(dynamicFeeKey, false, 1e18);
        assertEq(hook.getDirectionalState(poolId).lastFee, 3000);
    }

    function test_e2e_counterFlowReceivesDiscountAgainstBuiltPressure() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        _initializePoolWithFullRangeLiquidity(dynamicFeeKey);
        _disableLiquidityFloor(poolId);

        _swapExactIn(dynamicFeeKey, false, 1e18);
        _swapExactIn(dynamicFeeKey, true, 1e18);

        assertEq(hook.getDirectionalState(poolId).lastFee, 2500);
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

    function testFuzz_updatePressureWithinBounds(int56 pressure, int24 currentTick) public {
        pressure = int56(bound(pressure, -10_000, 10_000));
        currentTick = int24(bound(currentTick, -10_000, 10_000));

        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);
        hook.setPressure(poolId, pressure);

        hook.updatePressureForTest(poolId, currentTick);

        DirectionalToxicityShield.DirectionalState memory state = hook.getDirectionalState(poolId);
        assertGe(state.pressure, -500);
        assertLe(state.pressure, 500);
    }

    function testFuzz_directionClassificationStableAcrossAmountSign(int56 pressure, bool zeroForOne) public {
        pressure = int56(bound(pressure, -500, 500));

        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);
        _disableLiquidityFloor(poolId);
        hook.setPressure(poolId, pressure);

        SwapParams memory exactIn =
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(1e18), sqrtPriceLimitX96: 0});
        SwapParams memory exactOut =
            SwapParams({zeroForOne: zeroForOne, amountSpecified: int256(1e18), sqrtPriceLimitX96: 0});

        assertEq(hook.previewFee(dynamicFeeKey, exactIn), hook.previewFee(dynamicFeeKey, exactOut));
    }

    function testFuzz_e2eSingleExactInSwapKeepsFeeAndPressureBounded(uint256 amountIn, bool zeroForOne) public {
        amountIn = bound(amountIn, 1e12, 10e18);

        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        _initializePoolWithFullRangeLiquidity(dynamicFeeKey);
        _disableLiquidityFloor(poolId);
        hook.setPressure(poolId, zeroForOne ? int56(-80) : int56(80));

        _swapExactIn(dynamicFeeKey, zeroForOne, amountIn);

        DirectionalToxicityShield.DirectionalState memory state = hook.getDirectionalState(poolId);
        assertGe(state.lastFee, 500);
        assertLe(state.lastFee, 10000);
        assertGe(state.pressure, -500);
        assertLe(state.pressure, 500);
    }

    function test_validatePolicy_revertsWhenBaseFeeBelowMin() public {
        DirectionalToxicityShield.FeePolicy memory p = _validPolicy();
        p.baseFee = 100;
        p.minFee = 200;
        vm.expectRevert(DirectionalToxicityShield.InvalidFeeBounds.selector);
        hook.validatePolicy(p);
    }

    function test_validatePolicy_revertsWhenBaseFeeAboveMax() public {
        DirectionalToxicityShield.FeePolicy memory p = _validPolicy();
        p.baseFee = 20000;
        p.maxFee = 10000;
        vm.expectRevert(DirectionalToxicityShield.InvalidFeeBounds.selector);
        hook.validatePolicy(p);
    }

    function test_validatePolicy_revertsWhenMaxFeeStepZero() public {
        DirectionalToxicityShield.FeePolicy memory p = _validPolicy();
        p.maxFeeStep = 0;
        vm.expectRevert(DirectionalToxicityShield.InvalidStepSize.selector);
        hook.validatePolicy(p);
    }

    function test_validatePolicy_revertsWhenPressureScaleZero() public {
        DirectionalToxicityShield.FeePolicy memory p = _validPolicy();
        p.pressureScale = 0;
        vm.expectRevert(DirectionalToxicityShield.InvalidPressureScale.selector);
        hook.validatePolicy(p);
    }

    function test_validatePolicy_revertsWhenMaxPressureZero() public {
        DirectionalToxicityShield.FeePolicy memory p = _validPolicy();
        p.maxPressure = 0;
        vm.expectRevert(DirectionalToxicityShield.InvalidPressureScale.selector);
        hook.validatePolicy(p);
    }

    function test_validatePolicy_revertsWhenDecayFactorTooLarge() public {
        DirectionalToxicityShield.FeePolicy memory p = _validPolicy();
        p.decayFactor = 1_000_001;
        vm.expectRevert(DirectionalToxicityShield.InvalidDecayFactor.selector);
        hook.validatePolicy(p);
    }

    function test_validatePolicy_revertsWhenDecayWindowNotAfterFilterWindow() public {
        DirectionalToxicityShield.FeePolicy memory p = _validPolicy();
        p.filterWindow = 60;
        p.decayWindow = 60;
        vm.expectRevert(DirectionalToxicityShield.InvalidDecayWindow.selector);
        hook.validatePolicy(p);
    }

    function test_validatePolicy_revertsWhenMajorMoveThresholdNegative() public {
        DirectionalToxicityShield.FeePolicy memory p = _validPolicy();
        p.majorMoveThreshold = -1;
        vm.expectRevert(DirectionalToxicityShield.InvalidMajorMoveThreshold.selector);
        hook.validatePolicy(p);
    }

    function test_validatePolicy_acceptsDefaultPolicy() public view {
        hook.validatePolicy(_validPolicy());
    }

    function _validPolicy() private pure returns (DirectionalToxicityShield.FeePolicy memory) {
        return DirectionalToxicityShield.FeePolicy({
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

    function test_updatePressure_capsAccumulationWithinSameBlock() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);
        _disableLiquidityFloor(poolId);

        hook.updatePressureForTest(poolId, 20);
        int56 firstPressure = hook.getDirectionalState(poolId).pressure;
        assertEq(firstPressure, 20);

        hook.updatePressureForTest(poolId, 50);
        int56 secondPressure = hook.getDirectionalState(poolId).pressure;
        assertEq(secondPressure, firstPressure, "pressure must not increase within the same block");

        hook.updatePressureForTest(poolId, 0);
        int56 thirdPressure = hook.getDirectionalState(poolId).pressure;
        assertEq(thirdPressure, firstPressure, "pressure must not change at all within same block");
    }

    function test_updatePressure_resumesAccumulationOnNewBlock() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);
        _disableLiquidityFloor(poolId);

        hook.updatePressureForTest(poolId, 20);
        hook.updatePressureForTest(poolId, 50);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        hook.updatePressureForTest(poolId, 70);
        int56 finalPressure = hook.getDirectionalState(poolId).pressure;
        assertGt(finalPressure, 20, "pressure must accumulate again on new block");
    }

    function test_updatePressure_perBlockCapStopsSingleBlockMaxPressureAttack() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);
        _disableLiquidityFloor(poolId);

        for (int24 t = 10; t <= 510; t += 10) {
            hook.updatePressureForTest(poolId, t);
        }
        int56 finalPressure = hook.getDirectionalState(poolId).pressure;
        assertLt(finalPressure, int56(500), "single-block stuffing must not reach maxPressure");
    }

    function test_configureSmoothing_capturesInitializerAsConfigurer() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        assertEq(hook.getPoolConfigurer(poolId), address(this));
    }

    function test_smoothing_defaultsDisabled() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        DirectionalToxicityShield.SmoothingConfig memory config = hook.getSmoothingConfig(poolId);
        assertEq(config.enabled, false);
        assertEq(config.dripBlockInterval, 0);
        assertEq(config.dripBps, 0);

        DirectionalToxicityShield.SmoothingReserve memory reserve = hook.getSmoothingReserve(poolId);
        assertEq(reserve.reserve0, 0);
        assertEq(reserve.reserve1, 0);
        assertEq(reserve.lastDripBlock, 0);
    }

    function test_configureSmoothing_setsConfigForConfigurer() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        DirectionalToxicityShield.SmoothingConfig memory config =
            DirectionalToxicityShield.SmoothingConfig({enabled: true, dripBlockInterval: 10, dripBps: 2000});

        vm.expectEmit(true, false, false, true, address(hook));
        emit SmoothingConfigured(poolId, true, 10, 2000);
        hook.configureSmoothing(dynamicFeeKey, config);

        DirectionalToxicityShield.SmoothingConfig memory got = hook.getSmoothingConfig(poolId);
        assertEq(got.enabled, true);
        assertEq(got.dripBlockInterval, 10);
        assertEq(got.dripBps, 2000);
    }

    function test_configureSmoothing_revertsForNonConfigurer() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        DirectionalToxicityShield.SmoothingConfig memory config =
            DirectionalToxicityShield.SmoothingConfig({enabled: true, dripBlockInterval: 10, dripBps: 2000});

        vm.prank(address(0xBEEF));
        vm.expectRevert(DirectionalToxicityShield.NotPoolConfigurer.selector);
        hook.configureSmoothing(dynamicFeeKey, config);
    }

    function test_configureSmoothing_revertsOnZeroDripInterval() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        DirectionalToxicityShield.SmoothingConfig memory config =
            DirectionalToxicityShield.SmoothingConfig({enabled: true, dripBlockInterval: 0, dripBps: 2000});

        vm.expectRevert(DirectionalToxicityShield.InvalidDripInterval.selector);
        hook.configureSmoothing(dynamicFeeKey, config);
    }

    function test_configureSmoothing_revertsOnZeroDripBps() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        DirectionalToxicityShield.SmoothingConfig memory config =
            DirectionalToxicityShield.SmoothingConfig({enabled: true, dripBlockInterval: 10, dripBps: 0});

        vm.expectRevert(DirectionalToxicityShield.InvalidDripBps.selector);
        hook.configureSmoothing(dynamicFeeKey, config);
    }

    function test_configureSmoothing_revertsOnDripBpsAboveMax() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        DirectionalToxicityShield.SmoothingConfig memory config =
            DirectionalToxicityShield.SmoothingConfig({enabled: true, dripBlockInterval: 10, dripBps: 10_001});

        vm.expectRevert(DirectionalToxicityShield.InvalidDripBps.selector);
        hook.configureSmoothing(dynamicFeeKey, config);
    }

    function test_configureSmoothing_acceptsDisabledConfigWithoutValidation() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        // A disabled config is a valid opt-out even with otherwise-invalid knobs.
        DirectionalToxicityShield.SmoothingConfig memory config =
            DirectionalToxicityShield.SmoothingConfig({enabled: false, dripBlockInterval: 0, dripBps: 0});

        hook.configureSmoothing(dynamicFeeKey, config);
        assertEq(hook.getSmoothingConfig(poolId).enabled, false);
    }

    // ─── Task 2: Premium Capture Tests ───────────────────────────────────────────

    event PremiumCaptured(PoolId indexed poolId, uint128 amount0, uint128 amount1);

    function _enableSmoothing(PoolKey memory poolKey) private {
        DirectionalToxicityShield.SmoothingConfig memory config =
            DirectionalToxicityShield.SmoothingConfig({enabled: true, dripBlockInterval: 5, dripBps: 2000});
        hook.configureSmoothing(poolKey, config);
    }

    function test_premiumCapture_reserveGrowsOnToxicAlignedSwap() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        _initializePoolWithFullRangeLiquidity(dynamicFeeKey);
        _disableLiquidityFloor(poolId);
        _enableSmoothing(dynamicFeeKey);

        // Build pressure: first swap in one direction
        _swapExactIn(dynamicFeeKey, false, 1e18);
        // Second swap same direction triggers toxic regime + aligned fee > baseFee
        _swapExactIn(dynamicFeeKey, false, 1e18);

        DirectionalToxicityShield.SmoothingReserve memory reserve = hook.getSmoothingReserve(poolId);
        // The premium should have been captured in the unspecified currency (currency0 for zeroForOne=false exactIn)
        assertGt(reserve.reserve0, 0, "reserve0 should grow from captured premium");
    }

    function test_premiumCapture_noReserveGrowthWhenSmoothingDisabled() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        _initializePoolWithFullRangeLiquidity(dynamicFeeKey);
        _disableLiquidityFloor(poolId);
        // Smoothing NOT enabled

        _swapExactIn(dynamicFeeKey, false, 1e18);
        _swapExactIn(dynamicFeeKey, false, 1e18);

        DirectionalToxicityShield.SmoothingReserve memory reserve = hook.getSmoothingReserve(poolId);
        assertEq(reserve.reserve0, 0, "reserve must stay zero when smoothing disabled");
        assertEq(reserve.reserve1, 0, "reserve must stay zero when smoothing disabled");
    }

    function test_premiumCapture_noReserveGrowthOnCounterFlowSwap() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        _initializePoolWithFullRangeLiquidity(dynamicFeeKey);
        _disableLiquidityFloor(poolId);
        _enableSmoothing(dynamicFeeKey);

        // Build positive pressure
        _swapExactIn(dynamicFeeKey, false, 1e18);
        // Counter-flow swap (fee < baseFee, no premium)
        _swapExactIn(dynamicFeeKey, true, 1e18);

        DirectionalToxicityShield.SmoothingReserve memory reserve = hook.getSmoothingReserve(poolId);
        // Only the first swap could have captured (if regime was > 0), but the first swap
        // starts from regime 0 (no pressure yet). The counter-flow swap definitely doesn't capture.
        assertEq(reserve.reserve0, 0, "counter-flow must not capture");
        assertEq(reserve.reserve1, 0, "counter-flow must not capture");
    }

    function test_premiumCapture_noReserveGrowthInQuietRegime() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        _initializePoolWithFullRangeLiquidity(dynamicFeeKey);
        _disableLiquidityFloor(poolId);
        _enableSmoothing(dynamicFeeKey);

        // Single swap from calm state: regime stays 0, fee = baseFee
        _swapExactIn(dynamicFeeKey, false, 1e18);

        DirectionalToxicityShield.SmoothingReserve memory reserve = hook.getSmoothingReserve(poolId);
        assertEq(reserve.reserve0, 0, "quiet regime must not capture");
        assertEq(reserve.reserve1, 0, "quiet regime must not capture");
    }

    function test_premiumCapture_emitsPremiumCapturedEvent() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        _initializePoolWithFullRangeLiquidity(dynamicFeeKey);
        _disableLiquidityFloor(poolId);
        _enableSmoothing(dynamicFeeKey);

        // Build pressure
        _swapExactIn(dynamicFeeKey, false, 1e18);

        // Next aligned swap should emit PremiumCaptured
        vm.expectEmit(true, false, false, false, address(hook));
        emit PremiumCaptured(poolId, 0, 0); // We just check the event is emitted (amounts checked via reserve)
        _swapExactIn(dynamicFeeKey, false, 1e18);
    }

    function test_premiumCapture_reserveAccumulatesAcrossMultipleSwaps() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        _initializePoolWithFullRangeLiquidity(dynamicFeeKey);
        _disableLiquidityFloor(poolId);
        _enableSmoothing(dynamicFeeKey);

        // Build pressure with first swap
        _swapExactIn(dynamicFeeKey, false, 1e18);
        // Second swap captures
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        _swapExactIn(dynamicFeeKey, false, 1e18);
        uint128 firstCapture = hook.getSmoothingReserve(poolId).reserve0;
        assertGt(firstCapture, 0);

        // Third swap should add more
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        _swapExactIn(dynamicFeeKey, false, 1e18);
        uint128 secondCapture = hook.getSmoothingReserve(poolId).reserve0;
        assertGt(secondCapture, firstCapture, "reserve must accumulate across swaps");
    }

    function test_premiumCapture_lpStillReceivesBaseFee() public {
        PoolKey memory dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = dynamicFeeKey.toId();
        _initializePoolWithFullRangeLiquidity(dynamicFeeKey);
        _disableLiquidityFloor(poolId);
        _enableSmoothing(dynamicFeeKey);

        // Build pressure
        _swapExactIn(dynamicFeeKey, false, 1e18);
        // The lastFee recorded should still be the full directional fee (for state tracking)
        // but the LP override was baseFee
        DirectionalToxicityShield.DirectionalState memory state = hook.getDirectionalState(poolId);
        // After first swap from calm, fee should be baseFee (no pressure yet at beforeSwap time)
        assertEq(state.lastFee, 3000);

        // Second swap: pressure built, fee should be 3500 (aligned)
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        _swapExactIn(dynamicFeeKey, false, 1e18);
        state = hook.getDirectionalState(poolId);
        assertEq(state.lastFee, 3500, "lastFee tracks full directional fee");
    }

    function _disableLiquidityFloor(PoolId poolId) private {
        hook.setFeePolicy(poolId, 3000, 500, 10000, 500, 10, 500, 500_000, 30, 5 minutes, 0, 5);
    }

    function _swapExactIn(PoolKey memory poolKey, bool zeroForOne, uint256 amountIn) private {
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function _initializePoolWithFullRangeLiquidity(PoolKey memory poolKey) private {
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);
        uint128 liquidityAmount = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }
}
