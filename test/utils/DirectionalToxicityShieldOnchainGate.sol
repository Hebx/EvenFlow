// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

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

import {EasyPosm} from "./libraries/EasyPosm.sol";
import {BaseTest} from "./BaseTest.sol";
import {DirectionalToxicityShield} from "../../src/DirectionalToxicityShield.sol";

contract DirectionalToxicityShieldOnchainGate is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    DirectionalToxicityShield public hook;
    PoolKey public poolKey;
    Currency public currency0;
    Currency public currency1;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        hook = _deployHook();
        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
    }

    function assertCanonicalV4Deployments() external view {
        require(block.chainid != 31337, "OnchainGate: not a fork");
        assertEq(address(poolManager), AddressConstants.getPoolManagerAddress(block.chainid));
        assertEq(address(positionManager), AddressConstants.getPositionManagerAddress(block.chainid));
        assertEq(address(swapRouter), AddressConstants.getV4SwapRouterAddress(block.chainid));
        assertGt(address(poolManager).code.length, 0, "PoolManager missing");
        assertGt(address(positionManager).code.length, 0, "PositionManager missing");
        assertGt(address(swapRouter).code.length, 0, "SwapRouter missing");
    }

    function runDirectionalScenario() external returns (uint24 firstFee, uint24 secondFee, int56 pressure) {
        PoolId poolId = poolKey.toId();

        _initializePoolWithFullRangeLiquidity(poolKey);
        _swapExactIn(false, 1e18);
        firstFee = hook.getDirectionalState(poolId).lastFee;

        _swapExactIn(false, 1e18);
        DirectionalToxicityShield.DirectionalState memory state = hook.getDirectionalState(poolId);

        secondFee = state.lastFee;
        pressure = state.pressure;
    }

    function _deployHook() private returns (DirectionalToxicityShield deployedHook) {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(poolManager);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(DirectionalToxicityShield).creationCode, constructorArgs);

        deployedHook = new DirectionalToxicityShield{salt: salt}(poolManager);
        assertEq(address(deployedHook), hookAddress);
    }

    function _swapExactIn(bool zeroForOne, uint256 amountIn) private {
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

    function _initializePoolWithFullRangeLiquidity(PoolKey memory key) private {
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
