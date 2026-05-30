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

import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";

import {DirectionalToxicityShield} from "../src/DirectionalToxicityShield.sol";

import {console2} from "forge-std/console2.sol";

/// @notice Minimal view surface of the live Clanker static-fee hook.
interface IClankerHookView {
    function poolManager() external view returns (address);
}

/// @title Stage 4: Live-Production Comparison (Base mainnet fork)
/// @notice Deploys the Shield against the *real* canonical Uniswap v4 PoolManager used by
///         production hooks, proves a live production hook (Clanker static-fee) is co-located
///         on that same PoolManager, and contrasts adaptive-vs-static fee behavior on identical
///         swap flow.
/// @dev The Clanker-presence assertions are gated to a Base mainnet fork (chainid 8453). The
///      behavioral contrast runs everywhere (local + fork) using Clanker's observed static
///      config so the suite stays green in CI without a fork.
///
///      Run against real Base mainnet infrastructure:
///        forge test --match-contract DirectionalToxicityShieldMainnetComparisonTest \
///          --fork-url "$BASE_MAINNET_RPC_URL" -vv
contract DirectionalToxicityShieldMainnetComparisonTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    /// @dev Live Clanker static-fee hook on Base mainnet.
    address internal constant CLANKER_STATIC_FEE_HOOK = 0xDd5EeaFf7BD481AD55Db083062b13a3cdf0A68CC;
    uint256 internal constant BASE_CHAIN_ID = 8453;

    /// @dev Clanker static-fee config as observed on-chain (PoolInitialized fee pair, bps).
    ///      A static hook charges these fixed values per direction and never adapts to flow.
    uint24 internal constant CLANKER_FEE_AGGRESSIVE = 10_000; // 1.00%
    uint24 internal constant CLANKER_FEE_PAIRED = 5_000; // 0.50%

    uint24 internal constant SHIELD_BASE_FEE = 3_000; // 0.30%

    DirectionalToxicityShield internal shield;
    PoolKey internal shieldKey;
    Currency internal currency0;
    Currency internal currency1;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        shield = DirectionalToxicityShield(_deployShield());
        shieldKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(shield));
        poolManager.initialize(shieldKey, Constants.SQRT_PRICE_1_1);
        _addFullRangeLiquidity(shieldKey);
    }

    /// @notice Proves the comparison runs against real production infrastructure: our freshly
    ///         deployed Shield and the live Clanker hook share the exact same canonical PoolManager.
    function test_stage4ForkProvesLiveClankerHookIsCanonical() public view {
        if (block.chainid != BASE_CHAIN_ID) {
            console2.log("Skipping live-Clanker assertion: not a Base mainnet fork (chainid):", block.chainid);
            return;
        }

        // The Shield is deployed against the canonical Base v4 PoolManager.
        assertEq(
            address(poolManager),
            AddressConstants.getPoolManagerAddress(block.chainid),
            "Shield not bound to canonical PoolManager"
        );

        // The live production competitor is real and present on this chain.
        assertGt(CLANKER_STATIC_FEE_HOOK.code.length, 0, "Clanker static-fee hook has no code on Base mainnet");

        // ...and it is wired to the *same* canonical PoolManager the Shield uses.
        assertEq(
            IClankerHookView(CLANKER_STATIC_FEE_HOOK).poolManager(),
            address(poolManager),
            "Clanker hook does not share the canonical PoolManager"
        );

        console2.log("Live Clanker hook code size (bytes):", CLANKER_STATIC_FEE_HOOK.code.length);
        console2.log("Shared canonical PoolManager:", address(poolManager));
    }

    /// @notice Identical swap flow through the Shield vs a static-fee model. A static hook
    ///         charges a fixed fee per direction; the Shield escalates under continued toxic
    ///         pressure, discounts counter-flow, and decays back to base after a quiet period.
    function test_stage4ShieldAdaptsWhereStaticHookCannot() public {
        console2.log("");
        console2.log("=== Stage 4: Shield (adaptive) vs Clanker static-fee model ===");
        console2.log("Static hook charges a fixed fee per direction regardless of flow:");
        console2.log("  Clanker aggressive direction (bps):", CLANKER_FEE_AGGRESSIVE);
        console2.log("  Clanker paired direction (bps):    ", CLANKER_FEE_PAIRED);
        console2.log("");

        PoolId poolId = shieldKey.toId();

        // 1) Sustained toxic flow in one direction -> Shield should escalate above base.
        console2.log("-- Phase 1: sustained toxic flow (same direction) --");
        uint24 shieldFee;
        for (uint256 i = 0; i < 4; i++) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 12);
            _swapExactIn(shieldKey, false, 1e18);
            shieldFee = shield.getDirectionalState(poolId).lastFee;
            console2.log("  swap", i + 1);
            console2.log("    Shield adaptive fee (bps):", shieldFee);
            console2.log("    Static fee (bps):         ", CLANKER_FEE_AGGRESSIVE);
        }
        uint24 toxicFee = shield.getDirectionalState(poolId).lastFee;
        int56 toxicPressure = shield.getDirectionalState(poolId).pressure;
        assertGt(toxicFee, SHIELD_BASE_FEE, "Shield should escalate above base under toxic flow");
        assertGt(toxicPressure, int56(0), "Shield should accumulate positive directional pressure");

        // 2) Counter-flow -> Shield should discount below base (rewards rebalancing flow).
        console2.log("-- Phase 2: counter-flow swap --");
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        _swapExactIn(shieldKey, true, 1e18);
        uint24 counterFee = shield.getDirectionalState(poolId).lastFee;
        console2.log("    Shield counter-flow fee (bps):", counterFee);
        console2.log("    Static fee (bps):             ", CLANKER_FEE_PAIRED);
        assertLt(counterFee, SHIELD_BASE_FEE, "Shield should discount counter-flow below base");

        // 3) Quiet period -> Shield should decay back toward base; a static hook never moves.
        console2.log("-- Phase 3: quiet period then single swap --");
        vm.roll(block.number + 25);
        vm.warp(block.timestamp + 5 minutes);
        _swapExactIn(shieldKey, false, 1e18);
        uint24 decayedFee = shield.getDirectionalState(poolId).lastFee;
        console2.log("    Shield post-quiet fee (bps):", decayedFee);
        console2.log("    Static fee (bps):           ", CLANKER_FEE_AGGRESSIVE);
        assertLt(decayedFee, toxicFee, "Shield should decay after a quiet period");

        console2.log("");
        console2.log("Result: the static hook charged a constant fee in every phase; the Shield");
        console2.log("escalated under toxicity, discounted counter-flow, and decayed when quiet.");
    }

    // ==================== HELPERS ====================

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
}
