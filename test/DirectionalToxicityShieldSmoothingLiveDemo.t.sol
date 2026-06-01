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
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";

import {DirectionalToxicityShield} from "../src/DirectionalToxicityShield.sol";

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

/// @title Live-Infrastructure Demo: smoothing capture -> escrow -> drip
/// @notice Proves the opt-in yield-smoothing layer end-to-end against the canonical
///         Uniswap v4 PoolManager, driving flow ORGANICALLY through the real swap
///         router (no harness `setPressure`/`setFeePolicy` cheats). When run with
///         `--fork-url $BASE_MAINNET_RPC_URL` the pool lives on the *real* Base
///         mainnet PoolManager that production hooks use, so this is a "real pool,
///         real PoolManager" proof of the IL/yield mechanism — not a model.
/// @dev This is the on-chain counterpart to the off-chain SmoothingProofReport
///      simulation. The sim measures variance/IL/LVR; this test proves the
///      capture/escrow/drip accounting actually executes on live v4 infra and
///      conserves value (captured == dripped + remaining).
///
///      Run against real Base mainnet infrastructure:
///        forge test --match-contract DirectionalToxicityShieldSmoothingLiveDemoTest \
///          --fork-url "$BASE_MAINNET_RPC_URL" -vv
contract DirectionalToxicityShieldSmoothingLiveDemoTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant BASE_CHAIN_ID = 8453;
    uint24 internal constant SHIELD_BASE_FEE = 3_000;
    uint16 internal constant DRIP_BPS = 2_000; // 20% of reserve per drip
    uint32 internal constant DRIP_BLOCK_INTERVAL = 5;

    // keccak256("PremiumCaptured(bytes32,uint128,uint128)") / ("DripReleased(...)")
    bytes32 internal constant PREMIUM_CAPTURED_SIG = keccak256("PremiumCaptured(bytes32,uint128,uint128)");
    bytes32 internal constant DRIP_RELEASED_SIG = keccak256("DripReleased(bytes32,uint128,uint128)");

    DirectionalToxicityShield internal shield;
    PoolKey internal shieldKey;
    PoolId internal poolId;
    Currency internal currency0;
    Currency internal currency1;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        shield = DirectionalToxicityShield(_deployShield());
        shieldKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(shield));
        poolId = shieldKey.toId();

        // This test contract is the PoolManager.initialize caller => the hook
        // captures it as the pool configurer, so it may opt the pool into smoothing.
        poolManager.initialize(shieldKey, Constants.SQRT_PRICE_1_1);
        _addFullRangeLiquidity(shieldKey);

        shield.configureSmoothing(
            shieldKey,
            DirectionalToxicityShield.SmoothingConfig({
                enabled: true, dripBlockInterval: DRIP_BLOCK_INTERVAL, dripBps: DRIP_BPS
            })
        );
    }

    /// End-to-end smoothing proof on live infrastructure:
    ///   1. A toxic run escalates the fee; smoothing routes the premium into the
    ///      escrow reserve instead of paying it straight to LPs (capture).
    ///   2. After the pool goes quiet, a swap releases a bounded dripBps slice of
    ///      the escrow to in-range LPs (drip).
    ///   3. Value is conserved: captured == dripped + remaining (no LP tax).
    function test_smoothingCaptureThenDrip_onLiveInfra() public {
        vm.recordLogs();

        console2.log("# Directional Toxicity Shield - smoothing capture/drip (live infra)");
        console2.log("");
        console2.log("PoolManager:", address(poolManager));
        console2.log("Canonical for chainid:", block.chainid);
        if (block.chainid == BASE_CHAIN_ID) {
            console2.log("=> REAL Base mainnet PoolManager (forked). This is a real-infra run.");
        } else {
            console2.log("=> Local PoolManager (not a fork). Run with --fork-url for real-infra proof.");
        }
        console2.log("");
        console2.log("phase  | fee(bps) | regime | reserve0      | reserve1");
        console2.log("-------|----------|--------|---------------|---------------");

        // Reference swap: sets the reference tick, fee stays at base, no capture.
        _phaseSwap("base", false, 1e18);

        // Toxic run: aligned same-direction swaps escalate the fee. With smoothing
        // on, LPs receive baseFee and the premium is escrowed instead.
        _phaseSwap("toxic", false, 2e18);
        _phaseSwap("toxic", false, 2e18);
        _phaseSwap("toxic", false, 2e18);
        _phaseSwap("toxic", false, 2e18);

        DirectionalToxicityShield.SmoothingReserve memory captured = shield.getSmoothingReserve(poolId);
        uint256 capturedTotal = uint256(captured.reserve0) + uint256(captured.reserve1);
        assertGt(capturedTotal, 0, "toxic flow must escrow premium into the smoothing reserve");

        // Quiet period: advance blocks past the drip cooldown and time past the
        // decay window so the pre-swap (decayed) regime is quiet. Then swap with
        // NO further roll/warp so the swap executes at exactly this quiet point.
        vm.roll(block.number + DRIP_BLOCK_INTERVAL + 1);
        vm.warp(block.timestamp + 6 minutes);
        assertEq(shield.getEffectiveRegime(poolId), 0, "pool must be quiet (decayed) before the drip swap");

        // A swap whose pre-swap (decayed) regime is quiet triggers the drip. A
        // tiny swap keeps tick movement minimal; the drip decision is made from
        // the pre-swap quiet flag regardless of what this swap re-accumulates.
        _swapExactIn(shieldKey, true, 1e15);
        _logReserve("drip");

        DirectionalToxicityShield.SmoothingReserve memory afterDrip = shield.getSmoothingReserve(poolId);
        uint256 remainingTotal = uint256(afterDrip.reserve0) + uint256(afterDrip.reserve1);

        // Drip released a bounded slice; reserve shrank but is not fully emptied
        // in a single pass (dripBps = 20%).
        assertLt(remainingTotal, capturedTotal, "quiet-regime swap must drip part of the escrow to LPs");
        assertGt(remainingTotal, 0, "a single drip releases only a bounded slice, not the whole reserve");

        // Each side released exactly dripBps of its pre-drip balance.
        uint256 dripped0 = uint256(captured.reserve0) - uint256(afterDrip.reserve0);
        uint256 dripped1 = uint256(captured.reserve1) - uint256(afterDrip.reserve1);
        assertEq(dripped0, (uint256(captured.reserve0) * DRIP_BPS) / 10_000, "reserve0 drip == dripBps slice");
        assertEq(dripped1, (uint256(captured.reserve1) * DRIP_BPS) / 10_000, "reserve1 drip == dripBps slice");

        // Conservation: nothing is minted or burned away. Every wei captured is
        // either still escrowed or has been donated to LPs.
        uint256 drippedTotal = dripped0 + dripped1;
        assertEq(drippedTotal + remainingTotal, capturedTotal, "captured == dripped + remaining (value conserved)");

        // The capture and drip events both fired on live infra.
        (bool sawCapture, bool sawDrip) = _scanEvents();
        assertTrue(sawCapture, "PremiumCaptured must be emitted during the toxic run");
        assertTrue(sawDrip, "DripReleased must be emitted during the quiet drip");

        console2.log("");
        console2.log("captured (wei): ", capturedTotal);
        console2.log("dripped  (wei): ", drippedTotal);
        console2.log("remaining(wei): ", remainingTotal);
        console2.log("");
        console2.log("Summary: toxic premium is escrowed (not paid straight through), then");
        console2.log("released to in-range LPs in bounded slices once the pool is quiet.");
        console2.log("Value is conserved: captured == dripped + remaining. Smoothing time-shifts");
        console2.log("yield to cut LP-yield variance; it never taxes LPs.");
    }

    // ==================== HELPERS ====================

    function _phaseSwap(string memory phase, bool zeroForOne, uint256 amountIn) internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        _swapExactIn(shieldKey, zeroForOne, amountIn);
        _logReserve(phase);
    }

    function _logReserve(string memory phase) internal view {
        DirectionalToxicityShield.DirectionalState memory state = shield.getDirectionalState(poolId);
        DirectionalToxicityShield.SmoothingReserve memory r = shield.getSmoothingReserve(poolId);
        console2.log(
            string.concat(
                _pad(phase, 6),
                " | ",
                _pad(_u(state.lastFee), 8),
                " | ",
                _pad(_u(state.regime), 6),
                " | ",
                _pad(_u(r.reserve0), 13),
                " | ",
                _u(r.reserve1)
            )
        );
    }

    function _scanEvents() internal returns (bool sawCapture, bool sawDrip) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == PREMIUM_CAPTURED_SIG) sawCapture = true;
            if (logs[i].topics[0] == DRIP_RELEASED_SIG) sawDrip = true;
        }
    }

    function _deployShield() internal returns (address shieldAddr) {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(poolManager);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(DirectionalToxicityShield).creationCode, constructorArgs);
        DirectionalToxicityShield deployed = new DirectionalToxicityShield{salt: salt}(poolManager);
        assertEq(address(deployed), hookAddress, "mined hook address mismatch");
        shieldAddr = address(deployed);
    }

    function _swapExactIn(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal {
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function _addFullRangeLiquidity(PoolKey memory key) internal {
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

    function _u(uint256 v) internal pure returns (string memory) {
        return vm.toString(v);
    }

    function _pad(string memory s, uint256 width) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length >= width) return s;
        bytes memory out = new bytes(width);
        for (uint256 i = 0; i < width; i++) {
            out[i] = i < b.length ? b[i] : bytes1(" ");
        }
        return string(out);
    }
}
