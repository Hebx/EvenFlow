// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {DirectionalToxicityShieldHarness} from "./harness/DirectionalToxicityShieldHarness.sol";
import {DirectionalToxicityShield} from "../src/DirectionalToxicityShield.sol";
import {BaseTest} from "./utils/BaseTest.sol";

/// @dev Tests for the Reactive-automation entrypoints added in the Reactive LP
/// Shield upgrade: setReactiveExecutor, triggerQuietDrip (the stranded-reserve
/// fix), and applyPolicyMode. These exercise the executor-gated paths WITHOUT a
/// swap, proving the reserve can be released in a genuinely idle pool. The
/// off-chain trigger is simulated by pranking the configured executor address.
contract DirectionalToxicityShieldReactiveTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    event ReactiveExecutorSet(PoolId indexed poolId, address indexed executor);
    event ReactiveActionApplied(PoolId indexed poolId, uint8 actionType, uint40 atBlock);
    event ReactiveActionRejected(PoolId indexed poolId, uint8 actionType, uint8 reason);
    event PolicyModeUpdated(PoolId indexed poolId, uint8 mode, address indexed caller);
    event DripReleased(PoolId indexed poolId, uint128 amount0, uint128 amount1);

    uint8 private constant ACTION_DRIP = 1;
    uint8 private constant ACTION_POLICY_MODE = 2;
    uint8 private constant REASON_NOT_QUIET = 1;
    uint8 private constant REASON_NOT_ELIGIBLE = 2;
    uint8 private constant REASON_BAD_MODE = 3;

    address private constant EXECUTOR = address(0xE9EC);

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

    // ─── Executor wiring ─────────────────────────────────────────────────────────

    function test_setReactiveExecutor_setsAndEmits() public {
        PoolKey memory key = _freshPool();
        PoolId poolId = key.toId();

        vm.expectEmit(true, true, false, false, address(hook));
        emit ReactiveExecutorSet(poolId, EXECUTOR);
        hook.setReactiveExecutor(key, EXECUTOR);

        assertEq(hook.getReactiveExecutor(poolId), EXECUTOR);
    }

    function test_setReactiveExecutor_revertsForNonConfigurer() public {
        PoolKey memory key = _freshPool();

        vm.prank(address(0xBEEF));
        vm.expectRevert(DirectionalToxicityShield.NotPoolConfigurer.selector);
        hook.setReactiveExecutor(key, EXECUTOR);
    }

    function test_triggerQuietDrip_revertsForUnauthorizedCaller() public {
        PoolKey memory key = _freshPool();
        hook.setReactiveExecutor(key, EXECUTOR);

        vm.prank(address(0xBAD));
        vm.expectRevert(DirectionalToxicityShield.NotReactiveExecutor.selector);
        hook.triggerQuietDrip(key);
    }

    function test_triggerQuietDrip_revertsWhenNoExecutorWired() public {
        PoolKey memory key = _freshPool();
        // No executor set; default zero address. Any real (non-zero) caller must revert.
        vm.prank(address(0xBAD));
        vm.expectRevert(DirectionalToxicityShield.NotReactiveExecutor.selector);
        hook.triggerQuietDrip(key);
    }

    // ─── triggerQuietDrip: the stranded-reserve fix ──────────────────────────────

    function test_triggerQuietDrip_releasesStrandedReserveWithoutSwap() public {
        (PoolKey memory key, PoolId poolId) = _poolWithCapturedReserve();
        hook.setReactiveExecutor(key, EXECUTOR);

        // Decay pressure to quiet (regime 0) by advancing past decayWindow.
        vm.roll(block.number + 10);
        vm.warp(block.timestamp + 5 minutes);
        assertEq(hook.getEffectiveRegime(poolId), 0, "pool must be quiet");

        uint128 reserveBefore = hook.getSmoothingReserve(poolId).reserve0;
        assertGt(reserveBefore, 0, "precondition: reserve has stranded premium");

        // No swap. Reactive executor triggers the drip directly.
        vm.prank(EXECUTOR);
        vm.expectEmit(true, false, false, false, address(hook));
        emit DripReleased(poolId, 0, 0);
        hook.triggerQuietDrip(key);

        uint128 reserveAfter = hook.getSmoothingReserve(poolId).reserve0;
        assertLt(reserveAfter, reserveBefore, "reserve must decrease after Reactive drip");

        // Released exactly dripBps (2000 = 20%) of the reserve.
        uint128 expectedRelease = uint128((uint256(reserveBefore) * 2000) / 10_000);
        assertEq(reserveBefore - reserveAfter, expectedRelease, "drip releases exact dripBps fraction");
    }

    function test_triggerQuietDrip_emitsActionApplied() public {
        (PoolKey memory key, PoolId poolId) = _poolWithCapturedReserve();
        hook.setReactiveExecutor(key, EXECUTOR);
        vm.roll(block.number + 10);
        vm.warp(block.timestamp + 5 minutes);

        vm.prank(EXECUTOR);
        vm.expectEmit(true, false, false, false, address(hook));
        emit ReactiveActionApplied(poolId, ACTION_DRIP, 0);
        hook.triggerQuietDrip(key);
    }

    function test_triggerQuietDrip_rejectsWhenNotQuiet() public {
        (PoolKey memory key, PoolId poolId) = _poolWithCapturedReserve();
        hook.setReactiveExecutor(key, EXECUTOR);

        // Do NOT decay: pressure is still high (toxic regime). Reserve stays put.
        assertGt(hook.getEffectiveRegime(poolId), 0, "precondition: not quiet");
        uint128 reserveBefore = hook.getSmoothingReserve(poolId).reserve0;

        vm.prank(EXECUTOR);
        vm.expectEmit(true, false, false, true, address(hook));
        emit ReactiveActionRejected(poolId, ACTION_DRIP, REASON_NOT_QUIET);
        hook.triggerQuietDrip(key);

        assertEq(hook.getSmoothingReserve(poolId).reserve0, reserveBefore, "no release when not quiet");
    }

    function test_triggerQuietDrip_rejectsWhenReserveEmpty() public {
        PoolKey memory key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = key.toId();
        _addFullRangeLiquidity(key);
        _disableLiquidityFloor(poolId);
        _enableSmoothing(key);
        hook.setReactiveExecutor(key, EXECUTOR);

        // Quiet by construction (no pressure built) and empty reserve.
        vm.prank(EXECUTOR);
        vm.expectEmit(true, false, false, true, address(hook));
        emit ReactiveActionRejected(poolId, ACTION_DRIP, REASON_NOT_ELIGIBLE);
        hook.triggerQuietDrip(key);
    }

    function test_triggerQuietDrip_respectsCooldown() public {
        (PoolKey memory key, PoolId poolId) = _poolWithCapturedReserve();
        hook.setReactiveExecutor(key, EXECUTOR);
        vm.roll(block.number + 10);
        vm.warp(block.timestamp + 5 minutes);

        // First Reactive drip succeeds.
        vm.prank(EXECUTOR);
        hook.triggerQuietDrip(key);
        uint128 reserveAfterFirst = hook.getSmoothingReserve(poolId).reserve0;
        assertGt(reserveAfterFirst, 0, "reserve not fully drained");

        // Immediately retry (within dripBlockInterval = 5): rejected, reserve unchanged.
        vm.roll(block.number + 1);
        vm.prank(EXECUTOR);
        vm.expectEmit(true, false, false, true, address(hook));
        emit ReactiveActionRejected(poolId, ACTION_DRIP, REASON_NOT_ELIGIBLE);
        hook.triggerQuietDrip(key);
        assertEq(hook.getSmoothingReserve(poolId).reserve0, reserveAfterFirst, "cooldown blocks back-to-back drip");
    }

    // ─── applyPolicyMode ─────────────────────────────────────────────────────────

    function test_applyPolicyMode_guardedAndDefensivePresets() public {
        PoolKey memory key = _freshPool();
        PoolId poolId = key.toId();
        hook.setReactiveExecutor(key, EXECUTOR);

        // GUARDED (mode 1)
        vm.prank(EXECUTOR);
        vm.expectEmit(true, false, false, true, address(hook));
        emit PolicyModeUpdated(poolId, 1, EXECUTOR);
        hook.applyPolicyMode(key, 1);
        DirectionalToxicityShield.FeePolicy memory g = hook.getFeePolicy(poolId);
        assertEq(g.maxFee, 20_000);
        assertEq(g.maxFeeStep, 1_000);

        // DEFENSIVE (mode 2)
        vm.prank(EXECUTOR);
        hook.applyPolicyMode(key, 2);
        DirectionalToxicityShield.FeePolicy memory d = hook.getFeePolicy(poolId);
        assertEq(d.maxFee, 30_000);
        assertEq(d.maxFeeStep, 2_000);

        // NORMAL (mode 0) restores defaults
        vm.prank(EXECUTOR);
        hook.applyPolicyMode(key, 0);
        DirectionalToxicityShield.FeePolicy memory n = hook.getFeePolicy(poolId);
        assertEq(n.maxFee, 10_000);
        assertEq(n.maxFeeStep, 500);
    }

    function test_applyPolicyMode_rejectsOutOfRangeMode() public {
        PoolKey memory key = _freshPool();
        PoolId poolId = key.toId();
        hook.setReactiveExecutor(key, EXECUTOR);

        DirectionalToxicityShield.FeePolicy memory before = hook.getFeePolicy(poolId);

        vm.prank(EXECUTOR);
        vm.expectEmit(true, false, false, true, address(hook));
        emit ReactiveActionRejected(poolId, ACTION_POLICY_MODE, REASON_BAD_MODE);
        hook.applyPolicyMode(key, 3);

        // Policy unchanged on rejection.
        DirectionalToxicityShield.FeePolicy memory afterMode = hook.getFeePolicy(poolId);
        assertEq(afterMode.maxFee, before.maxFee);
        assertEq(afterMode.maxFeeStep, before.maxFeeStep);
    }

    function test_applyPolicyMode_revertsForUnauthorizedCaller() public {
        PoolKey memory key = _freshPool();
        hook.setReactiveExecutor(key, EXECUTOR);

        vm.prank(address(0xBAD));
        vm.expectRevert(DirectionalToxicityShield.NotReactiveExecutor.selector);
        hook.applyPolicyMode(key, 1);
    }

    // ─── Isolation ────────────────────────────────────────────────────────────────

    function test_reactiveExecutor_isolatedPerPool() public {
        PoolKey memory keyA = _freshPool();
        hook.setReactiveExecutor(keyA, EXECUTOR);

        // A second pool (different fee tier id via tickSpacing) has no executor.
        PoolKey memory keyB = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 30, IHooks(hook));
        poolManager.initialize(keyB, Constants.SQRT_PRICE_1_1);

        assertEq(hook.getReactiveExecutor(keyA.toId()), EXECUTOR);
        assertEq(hook.getReactiveExecutor(keyB.toId()), address(0));

        // EXECUTOR cannot act on pool B.
        vm.prank(EXECUTOR);
        vm.expectRevert(DirectionalToxicityShield.NotReactiveExecutor.selector);
        hook.triggerQuietDrip(keyB);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────────

    function _freshPool() private returns (PoolKey memory key) {
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
    }

    /// @dev Initialize a pool with liquidity, smoothing enabled, and a non-empty
    /// reserve built from a toxic-aligned swap sequence. Leaves the pool in a
    /// toxic regime (caller decides whether to decay to quiet).
    function _poolWithCapturedReserve() private returns (PoolKey memory key, PoolId poolId) {
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = key.toId();
        _addFullRangeLiquidity(key);
        _disableLiquidityFloor(poolId);
        _enableSmoothing(key);

        _swapExactIn(key, false, 1e18);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        _swapExactIn(key, false, 1e18);

        require(hook.getSmoothingReserve(poolId).reserve0 > 0, "setup: reserve not captured");
    }

    function _enableSmoothing(PoolKey memory key) private {
        hook.configureSmoothing(
            key, DirectionalToxicityShield.SmoothingConfig({enabled: true, dripBlockInterval: 5, dripBps: 2000})
        );
    }

    function _disableLiquidityFloor(PoolId poolId) private {
        hook.setFeePolicy(poolId, 3000, 500, 10000, 500, 10, 500, 500_000, 30, 5 minutes, 0, 5);
    }

    function _swapExactIn(PoolKey memory key, bool zeroForOne, uint256 amountIn) private {
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: type(uint256).max
        });
    }

    function _addFullRangeLiquidity(PoolKey memory key) private {
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        uint128 liquidityAmount = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        positionManager.mint(
            key,
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
