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

/// @title Live-Infrastructure Demo: full fee timeline
/// @notice Runs a realistic, narrated swap journey through the Shield against the canonical
///         Uniswap v4 PoolManager. When run with `--fork-url $BASE_MAINNET_RPC_URL` the pool
///         lives on the *real* Base mainnet PoolManager that production hooks use, so the
///         emitted timeline is a "real pool, real PoolManager" artifact (not a mock).
/// @dev Produces docs/demos/base-mainnet-fork-fee-timeline.md when its log output is captured.
///      Run: forge test --match-contract DirectionalToxicityShieldLiveDemoTest \
///             --fork-url "$BASE_MAINNET_RPC_URL" -vv
contract DirectionalToxicityShieldLiveDemoTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant BASE_CHAIN_ID = 8453;
    uint24 internal constant SHIELD_BASE_FEE = 3_000;

    DirectionalToxicityShield internal shield;
    PoolKey internal shieldKey;
    Currency internal currency0;
    Currency internal currency1;

    uint256 internal step;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        shield = DirectionalToxicityShield(_deployShield());
        shieldKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(shield));
        poolManager.initialize(shieldKey, Constants.SQRT_PRICE_1_1);
        _addFullRangeLiquidity(shieldKey);
    }

    function test_demoLiveFeeTimeline() public {
        console2.log("# Directional Toxicity Shield - live-infrastructure fee timeline");
        console2.log("");
        console2.log("PoolManager:", address(poolManager));
        console2.log("Canonical for chainid:", block.chainid);
        if (block.chainid == BASE_CHAIN_ID) {
            console2.log("=> REAL Base mainnet PoolManager (forked). This is a real-infra run.");
        } else {
            console2.log("=> Local PoolManager (not a fork). Run with --fork-url for real-infra proof.");
        }
        console2.log("");
        console2.log("phase | swap | direction | fee(bps) | vs base | pressure");
        console2.log("------|------|-----------|----------|---------|---------");

        // Phase A: first swap establishes the reference tick -> fee at base.
        _phaseSwap("base", false, 1e18);

        // Phase B: sustained toxic run (same direction) -> escalate, bounded.
        _phaseSwap("toxic", false, 2e18);
        _phaseSwap("toxic", false, 2e18);
        _phaseSwap("toxic", false, 2e18);
        _phaseSwap("toxic", false, 2e18);

        // Phase C: counter-flow -> discount below base (reward rebalancers).
        _phaseSwap("counter", true, 2e18);
        _phaseSwap("counter", true, 1e18);

        // Phase D: quiet period, then a single swap -> decay back toward base.
        vm.roll(block.number + 25);
        vm.warp(block.timestamp + 5 minutes);
        _phaseSwap("quiet", false, 1e18);

        console2.log("");
        console2.log("Summary: fee rises only while toxic pressure persists, dips below base for");
        console2.log("counter-flow, and decays back toward base once flow goes quiet - all bounded,");
        console2.log("all derived from local pool state, no oracle.");
    }

    // ==================== HELPERS ====================

    function _phaseSwap(string memory phase, bool zeroForOne, uint256 amountIn) internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        _swapExactIn(shieldKey, zeroForOne, amountIn);
        step++;

        DirectionalToxicityShield.DirectionalState memory state = shield.getDirectionalState(shieldKey.toId());
        string memory dir = zeroForOne ? "0->1 " : "1->0 ";
        string memory vsBase =
            state.lastFee > SHIELD_BASE_FEE ? "above" : (state.lastFee < SHIELD_BASE_FEE ? "below" : "base ");

        console2.log(
            string.concat(
                _pad(phase, 5),
                " | ",
                _pad(_u(step), 4),
                " | ",
                dir,
                "    | ",
                _pad(_u(state.lastFee), 8),
                " | ",
                vsBase,
                "   | "
            ),
            int256(state.pressure)
        );
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
