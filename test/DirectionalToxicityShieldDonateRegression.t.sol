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

/// @notice Regression coverage for the smoothing capture/drip ERC-6909 + donate
/// path on edges the existing suite missed:
///   1. exactOutput capture (premium taken from the input side, not output).
///   2. Two-sided drip when both reserve0 and reserve1 are non-zero.
///   3. Direct unlockCallback callers are rejected (only the PoolManager may
///      drive the donate body).
/// All three exercise live PoolManager state, so they would catch any future
/// accounting drift in the take/settle/donate triple.
contract DirectionalToxicityShieldDonateRegressionTest is BaseTest {
    using EasyPosm for IPositionManager;
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
                    | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144)
        );
        deployCodeTo(
            "DirectionalToxicityShieldHarness.sol:DirectionalToxicityShieldHarness", abi.encode(poolManager), flags
        );
        hook = DirectionalToxicityShieldHarness(flags);
    }

    /// exactOutput aligned swap: the unspecified currency is the INPUT, so
    /// premium must be captured on the input side. Mirrors what the canonical
    /// OZ BaseDynamicAfterFee does with `feeAmount.toInt128()` increasing the
    /// input-side debt of the swapper.
    function test_premiumCapture_exactOutput_capturesOnInputSide() public {
        PoolKey memory key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = key.toId();
        _initializePool(key);
        _disableLiquidityFloor(poolId);
        _enableSmoothing(key);

        // Force toxic regime so an aligned swap captures premium.
        hook.setPressure(poolId, 200);

        // zeroForOne=false aligned with positive pressure (premium side).
        // exactOutput (positive amountSpecified) => specified currency is the
        // OUTPUT (currency0 here), so unspecified is the INPUT (currency1).
        swapRouter.swapTokensForExactTokens({
            amountOut: 1e17,
            amountInMax: 5e18,
            zeroForOne: false,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: type(uint256).max
        });

        DirectionalToxicityShield.SmoothingReserve memory r = hook.getSmoothingReserve(poolId);
        // Capture lands on currency1 (the input/unspecified side) for this swap.
        assertGt(r.reserve1, 0, "exactOutput aligned swap captures premium on input side");
        assertEq(r.reserve0, 0, "exactOutput swap does not touch the output-side reserve");
    }

    /// A drip with non-zero balances on BOTH sides must settle and donate both
    /// currencies in a single pass. This is the path that exercises the full
    /// burn -> donate netting on two currencies at once.
    function test_drip_twoSided_releasesBothCurrencies() public {
        PoolKey memory key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = key.toId();
        _initializePool(key);
        _disableLiquidityFloor(poolId);
        _enableSmoothing(key);

        // Side A: build positive pressure, capture on currency0 via an aligned
        // exactInput zeroForOne=false swap (output side).
        hook.setPressure(poolId, 200);
        _swapExactIn(key, false, 1e18);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        _swapExactIn(key, false, 1e18);

        // Side B: build negative pressure, capture on currency1 via an aligned
        // exactInput zeroForOne=true swap. Reset pressure so we cleanly bias
        // the other direction without smoothing flipping.
        hook.setPressure(poolId, -200);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        _swapExactIn(key, true, 1e18);

        DirectionalToxicityShield.SmoothingReserve memory before_ = hook.getSmoothingReserve(poolId);
        assertGt(before_.reserve0, 0, "reserve0 captured");
        assertGt(before_.reserve1, 0, "reserve1 captured");

        // Force quiet regime + advance the cooldown.
        hook.setPressure(poolId, 0);
        vm.roll(block.number + 10);
        vm.warp(block.timestamp + 5 minutes);

        // A small swap in quiet regime triggers a drip; both sides must shrink.
        _swapExactIn(key, true, 0.1e18);

        DirectionalToxicityShield.SmoothingReserve memory after_ = hook.getSmoothingReserve(poolId);
        assertLt(after_.reserve0, before_.reserve0, "two-sided drip reduces reserve0");
        assertLt(after_.reserve1, before_.reserve1, "two-sided drip reduces reserve1");

        // Each side should have released exactly dripBps (2000 = 20%) of its
        // pre-drip balance, regardless of the other side's balance.
        uint128 expectedRelease0 = uint128((uint256(before_.reserve0) * 2000) / 10_000);
        uint128 expectedRelease1 = uint128((uint256(before_.reserve1) * 2000) / 10_000);
        assertEq(before_.reserve0 - after_.reserve0, expectedRelease0, "reserve0 released exact dripBps fraction");
        assertEq(before_.reserve1 - after_.reserve1, expectedRelease1, "reserve1 released exact dripBps fraction");
    }

    /// Direct callers must not be able to invoke unlockCallback; only the
    /// PoolManager (during a hook-initiated unlock) is allowed. This guard is
    /// what makes the Reactive-driven drip safe: the executor goes through
    /// triggerQuietDrip -> poolManager.unlock(...) -> unlockCallback.
    function test_unlockCallback_revertsForNonPoolManager() public {
        PoolKey memory key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        _initializePool(key);

        // BaseHook's onlyPoolManager modifier reverts with NotPoolManager().
        // We don't import the selector here; rely on a generic revert assertion.
        vm.expectRevert();
        hook.unlockCallback(abi.encode(key));
    }

    // ─── helpers (kept local to keep this file self-contained) ──────────────

    function _initializePool(PoolKey memory key) private {
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        uint128 liquidityAmount = 100e18;
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
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
            a0 + 1,
            a1 + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    function _disableLiquidityFloor(PoolId poolId) private {
        hook.setFeePolicy(poolId, 3000, 500, 10000, 500, 10, 500, 500_000, 30, 5 minutes, 0, 5);
    }

    function _enableSmoothing(PoolKey memory key) private {
        hook.configureSmoothing(
            key, DirectionalToxicityShield.SmoothingConfig({enabled: true, dripBlockInterval: 5, dripBps: 2000})
        );
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
}
