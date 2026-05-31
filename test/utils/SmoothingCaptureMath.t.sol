// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
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

import {EasyPosm} from "./libraries/EasyPosm.sol";
import {BaseTest} from "./BaseTest.sol";
import {DirectionalToxicityShieldHarness} from "../harness/DirectionalToxicityShieldHarness.sol";
import {DirectionalToxicityShield} from "../../src/DirectionalToxicityShield.sol";
import {SmoothingCaptureMath} from "../../script/utils/SmoothingCaptureMath.sol";

/// @notice Phase 2 of the smoothing IL/yield proof layer: pin the pure
/// capture/drip model to the deployed contract math. Two layers:
///  1. Pure unit checks of {SmoothingCaptureMath} against hand-computed values.
///  2. A contract-parity test: drive a real capturing swap through the hook,
///     read the applied directional fee (FeeOverrideApplied) and the gross
///     unspecified-currency amount (v4 Swap event), and assert the pure library
///     reproduces the observed on-chain reserve growth to the wei.
///
/// This guards the off-chain proof/sim from silently drifting away from the
/// shipped logic. Spec: docs/plans/2026-05-30-smoothing-il-yield-proof-prd.md WS1.
contract SmoothingCaptureMathTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    // Event topics for log parsing.
    bytes32 private constant FEE_OVERRIDE_TOPIC0 = keccak256("FeeOverrideApplied(bytes32,bool,uint24,int56,uint8)");
    bytes32 private constant SWAP_TOPIC0 =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    uint24 private constant BASE_FEE = 3000;

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

    // ─── Pure unit checks ────────────────────────────────────────────────────

    function test_capturePremiumBps_matchesFormula() public pure {
        // fee=3500, base=3000 → (500 * 10_000) / 3500 = 1428 (floor)
        assertEq(SmoothingCaptureMath.capturePremiumBps(3500, 3000), 1428, "premiumBps floor");
        // fee=3200, base=3000 → (200 * 10_000) / 3200 = 625 exactly
        assertEq(SmoothingCaptureMath.capturePremiumBps(3200, 3000), 625, "premiumBps exact");
    }

    function test_capturePremiumBps_zeroWhenNotAboveBase() public pure {
        assertEq(SmoothingCaptureMath.capturePremiumBps(3000, 3000), 0, "no premium at base");
        assertEq(SmoothingCaptureMath.capturePremiumBps(2500, 3000), 0, "no premium below base (counter-flow)");
    }

    function test_capturedAmount_matchesFormula() public pure {
        // absUnspecified = 1e18, fee=3500, base=3000 → premiumBps=1428
        // captured = 1e18 * 1428 / 10_000 = 1.428e17
        uint256 captured = SmoothingCaptureMath.capturedAmount(1e18, 3500, 3000);
        assertEq(captured, (uint256(1e18) * 1428) / 10_000, "captured == abs * premiumBps / 1e4");
        assertEq(captured, 142800000000000000, "captured literal");
    }

    function test_capturedAmount_zeroOnCounterFlow() public pure {
        assertEq(SmoothingCaptureMath.capturedAmount(1e18, 2500, 3000), 0, "counter-flow captures nothing");
    }

    function test_dripAmount_matchesFormula() public pure {
        // reserve=1e18, dripBps=2000 → 2e17
        assertEq(SmoothingCaptureMath.dripAmount(1e18, 2000), 2e17, "drip == reserve * dripBps / 1e4");
        // dust: reserve=4, dripBps=2000 → 0 (floor) — mirrors the dust skip
        assertEq(SmoothingCaptureMath.dripAmount(4, 2000), 0, "drip floors to dust");
    }

    // ─── Contract parity ──────────────────────────────────────────────────────

    /// The library must reproduce the contract's captured premium to the wei on
    /// the exact same swap. We read the inputs the contract used (applied fee +
    /// gross unspecified amount) straight from the emitted logs, so this is a
    /// true cross-check, not a re-derivation of the same intermediate.
    function test_parity_capturedPremiumMatchesContractToTheWei() public {
        PoolKey memory key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = key.toId();
        _initPool(key);
        _disableLiquidityFloor(poolId);
        _enableSmoothing(key);

        // First swap builds pressure (regime 0 at beforeSwap → no capture).
        _swapExactIn(key, false, 1e18);

        // Second swap captures. Record its logs to pull the exact inputs.
        uint128 reserveBefore = hook.getSmoothingReserve(poolId).reserve0;
        vm.recordLogs();
        _swapExactIn(key, false, 1e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint128 reserveAfter = hook.getSmoothingReserve(poolId).reserve0;
        uint256 observedGrowth = uint256(reserveAfter - reserveBefore);
        assertGt(observedGrowth, 0, "the capturing swap grew reserve0");

        // Parse the directional fee the contract used for premium calc, and the
        // gross unspecified (currency0) output it skimmed from.
        (uint24 appliedFee, bool found) = _findFeeOverride(logs, poolId);
        assertTrue(found, "FeeOverrideApplied present");
        assertGt(appliedFee, BASE_FEE, "capturing swap had fee > baseFee");

        uint256 absUnspecified = _findSwapAmount0Abs(logs, poolId);
        assertGt(absUnspecified, 0, "swap moved currency0");

        uint256 modelCaptured = SmoothingCaptureMath.capturedAmount(absUnspecified, appliedFee, BASE_FEE);
        assertEq(observedGrowth, modelCaptured, "pure model == contract capture, to the wei");
    }

    /// Drip parity: prime a reserve, go quiet, and assert the contract's donated
    /// drip equals `reserve * dripBps / 10_000` from the pure library.
    function test_parity_dripAmountMatchesContractToTheWei() public {
        PoolKey memory key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = key.toId();
        _initPool(key);
        _disableLiquidityFloor(poolId);
        _enableSmoothing(key); // dripBps = 2000, interval = 5 blocks

        // Build pressure + capture into the reserve.
        _swapExactIn(key, false, 1e18);
        _swapExactIn(key, false, 1e18);
        uint128 reservePrimed = hook.getSmoothingReserve(poolId).reserve0;
        assertGt(reservePrimed, 0, "reserve primed");

        // Go quiet: advance past decayWindow so pressure decays to regime 0, and
        // past the drip cooldown. A tiny swap in the quiet regime fires the drip.
        vm.roll(block.number + 10);
        vm.warp(block.timestamp + 6 minutes);

        uint256 expectedDrip = SmoothingCaptureMath.dripAmount(reservePrimed, 2000);

        _swapExactIn(key, false, 1); // minimal swap; quiet at beforeSwap → drip path
        uint128 reserveAfter = hook.getSmoothingReserve(poolId).reserve0;

        // The drip reduced the reserve by exactly the bounded fraction. (A tiny
        // capture could re-add on this swap, but from calm/quiet regime the swap
        // does not capture, so the only delta is the drip.)
        uint256 observedDrip = uint256(reservePrimed - reserveAfter);
        assertEq(observedDrip, expectedDrip, "contract drip == reserve * dripBps / 1e4, to the wei");
    }

    // ─── Log parsing helpers ───────────────────────────────────────────────────

    function _findFeeOverride(Vm.Log[] memory logs, PoolId poolId) private pure returns (uint24 fee, bool found) {
        bytes32 wantId = PoolId.unwrap(poolId);
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length >= 2 && logs[i].topics[0] == FEE_OVERRIDE_TOPIC0 && logs[i].topics[1] == wantId) {
                (, uint24 f,,) = abi.decode(logs[i].data, (bool, uint24, int56, uint8));
                return (f, true);
            }
        }
        return (0, false);
    }

    function _findSwapAmount0Abs(Vm.Log[] memory logs, PoolId poolId) private pure returns (uint256) {
        bytes32 wantId = PoolId.unwrap(poolId);
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length >= 2 && logs[i].topics[0] == SWAP_TOPIC0 && logs[i].topics[1] == wantId) {
                (int128 amount0,,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return amount0 < 0 ? uint256(uint128(-amount0)) : uint256(uint128(amount0));
            }
        }
        return 0;
    }

    // ─── Setup helpers (mirror DirectionalToxicityShield.t.sol) ─────────────────

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

    function _initPool(PoolKey memory key) private {
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
}
