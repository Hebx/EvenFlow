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
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";

import {DirectionalToxicityShield} from "../src/DirectionalToxicityShield.sol";
import {
    JdsAsymmetricFeesComparator,
    RegisNezlobinComparator,
    InfHookNezlobinComparator,
    VpinDynamicFeeComparator
} from "../src/comparators/PriorArtComparators.sol";

import {console2} from "forge-std/console2.sol";

/// @title Level B: Unified Prior-Art Comparison Test
/// @notice Deploys real bytecode of Shield + 4 prior-art hooks, pushes identical swap traces,
///         and compares actual fee behavior side-by-side.
contract PriorArtComparisonTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    Currency currency0;
    Currency currency1;

    DirectionalToxicityShield shield;
    JdsAsymmetricFeesComparator jds;
    RegisNezlobinComparator regis;
    InfHookNezlobinComparator infHook;
    VpinDynamicFeeComparator vpin;

    PoolKey shieldKey;
    PoolKey jdsKey;
    PoolKey regisKey;
    PoolKey infHookKey;
    PoolKey vpinKey;

    struct FeeSnapshot {
        uint24 shieldFee;
        uint24 jdsFee;
        uint24 regisFee;
        uint24 infHookFee;
        uint24 vpinFee;
    }

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        // Deploy Shield
        address shieldAddr = _deployHookAt(
            "DirectionalToxicityShield",
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG,
            0x1111
        );
        shield = DirectionalToxicityShield(shieldAddr);

        // Deploy JDS (beforeInitialize + beforeSwap)
        address jdsAddr =
            _deployHookAt("JdsAsymmetricFeesComparator", Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG, 0x2222);
        jds = JdsAsymmetricFeesComparator(jdsAddr);

        // Deploy Regis (afterInitialize + beforeSwap)
        address regisAddr =
            _deployHookAt("RegisNezlobinComparator", Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG, 0x3333);
        regis = RegisNezlobinComparator(regisAddr);

        // Deploy InfHook (beforeInitialize + beforeSwap)
        address infHookAddr =
            _deployHookAt("InfHookNezlobinComparator", Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG, 0x4444);
        infHook = InfHookNezlobinComparator(infHookAddr);

        // Deploy VPIN (beforeInitialize + afterInitialize + beforeSwap + afterSwap)
        address vpinAddr = _deployHookAt(
            "VpinDynamicFeeComparator",
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG,
            0x5555
        );
        vpin = VpinDynamicFeeComparator(vpinAddr);

        // Create pool keys
        shieldKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(shield));
        jdsKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(jds));
        regisKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(regis));
        infHookKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(infHook));
        vpinKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(vpin));

        // Initialize all pools at same price
        poolManager.initialize(shieldKey, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(jdsKey, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(regisKey, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(infHookKey, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(vpinKey, Constants.SQRT_PRICE_1_1);

        // Add identical liquidity to all pools
        _addFullRangeLiquidity(shieldKey);
        _addFullRangeLiquidity(jdsKey);
        _addFullRangeLiquidity(regisKey);
        _addFullRangeLiquidity(infHookKey);
        _addFullRangeLiquidity(vpinKey);
    }

    // ==================== SCENARIO TESTS ====================

    function test_scenario_sameDirectionToxicFlow() public {
        console2.log("");
        console2.log("=== SCENARIO: Same-direction toxic flow (4 swaps zeroForOne=false) ===");

        for (uint256 i = 0; i < 4; i++) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 12);

            FeeSnapshot memory fees = _swapAllPools(false, 1e18);
            _logFees(i + 1, fees);
        }

        // Verify Shield shows fee escalation
        DirectionalToxicityShield.DirectionalState memory state = shield.getDirectionalState(shieldKey.toId());
        assertGt(state.pressure, 0, "Shield pressure should be positive after same-direction flow");
        assertGt(state.lastFee, 3000, "Shield fee should exceed base after toxic flow");
    }

    function test_scenario_alternatingFlow() public {
        console2.log("");
        console2.log("=== SCENARIO: Alternating flow (buy/sell/buy/sell) ===");

        bool[4] memory directions = [false, true, false, true];

        for (uint256 i = 0; i < 4; i++) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 12);

            FeeSnapshot memory fees = _swapAllPools(directions[i], 1e18);
            _logFees(i + 1, fees);
        }

        // Shield should stay near base fee with alternating flow
        DirectionalToxicityShield.DirectionalState memory state = shield.getDirectionalState(shieldKey.toId());
        assertLe(state.lastFee, 3500, "Shield fee should stay moderate with alternating flow");
    }

    function test_scenario_toxicThenQuiet() public {
        console2.log("");
        console2.log("=== SCENARIO: Toxic flow then quiet period ===");

        // Phase 1: 3 toxic same-direction swaps
        for (uint256 i = 0; i < 3; i++) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 12);
            _swapAllPools(false, 1e18);
        }

        DirectionalToxicityShield.DirectionalState memory midState = shield.getDirectionalState(shieldKey.toId());
        uint24 midFee = midState.lastFee;
        console2.log("After 3 toxic swaps:");
        console2.log("  Shield fee:", midFee);
        console2.log("  pressure:", int256(midState.pressure));

        // Phase 2: quiet period (5 minutes)
        vm.warp(block.timestamp + 5 minutes);
        vm.roll(block.number + 25);

        // Phase 3: one more swap after quiet
        FeeSnapshot memory fees = _swapAllPools(false, 1e18);
        console2.log("After 5min quiet + swap:");
        _logFees(4, fees);

        // Shield should have decayed
        assertLt(fees.shieldFee, midFee, "Shield fee should decay after quiet period");
    }

    function test_scenario_counterFlowDiscount() public {
        console2.log("");
        console2.log("=== SCENARIO: Build pressure then counter-flow ===");

        // Build pressure with 3 same-direction swaps
        for (uint256 i = 0; i < 3; i++) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 12);
            _swapAllPools(false, 1e18);
        }

        DirectionalToxicityShield.DirectionalState memory state = shield.getDirectionalState(shieldKey.toId());
        console2.log("After pressure build:");
        console2.log("  Shield pressure:", int256(state.pressure));

        // Counter-flow swap
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        FeeSnapshot memory fees = _swapAllPools(true, 1e18);

        console2.log("Counter-flow swap:");
        _logFees(4, fees);

        // Shield should discount counter-flow
        assertLt(fees.shieldFee, 3000, "Shield should discount counter-flow below base fee");
    }

    // ==================== HELPERS ====================

    function _logFees(uint256 swapNum, FeeSnapshot memory fees) internal pure {
        console2.log("  Swap", swapNum);
        console2.log("    Shield:", fees.shieldFee);
        console2.log("    JDS:", fees.jdsFee);
        console2.log("    Regis:", fees.regisFee);
        console2.log("    InfHook:", fees.infHookFee);
        console2.log("    VPIN:", fees.vpinFee);
    }

    function _swapAllPools(bool zeroForOne, uint256 amountIn) internal returns (FeeSnapshot memory fees) {
        _swapExactIn(shieldKey, zeroForOne, amountIn);
        fees.shieldFee = shield.getDirectionalState(shieldKey.toId()).lastFee;

        _swapExactIn(jdsKey, zeroForOne, amountIn);
        fees.jdsFee = jds.lastAppliedFee(jdsKey.toId());

        _swapExactIn(regisKey, zeroForOne, amountIn);
        fees.regisFee = regis.lastAppliedFee(regisKey.toId());

        _swapExactIn(infHookKey, zeroForOne, amountIn);
        fees.infHookFee = infHook.lastAppliedFee(infHookKey.toId());

        _swapExactIn(vpinKey, zeroForOne, amountIn);
        fees.vpinFee = vpin.lastAppliedFee(vpinKey.toId());
    }

    function _swapExactIn(PoolKey memory poolKey, bool zeroForOne, uint256 amountIn) internal {
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

    function _addFullRangeLiquidity(PoolKey memory poolKey) internal {
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

    function _deployHookAt(string memory contractName, uint160 flags, uint160 salt)
        internal
        returns (address hookAddr)
    {
        hookAddr = address(uint160(flags) ^ (salt << 144));
        string memory artifact = contractName;

        // Map to correct artifact path
        if (_strEq(contractName, "DirectionalToxicityShield")) {
            artifact = "DirectionalToxicityShield.sol:DirectionalToxicityShield";
        } else {
            artifact = string.concat("PriorArtComparators.sol:", contractName);
        }

        deployCodeTo(artifact, abi.encode(poolManager), hookAddr);
    }

    function _strEq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
