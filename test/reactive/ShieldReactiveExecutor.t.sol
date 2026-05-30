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

import {EasyPosm} from "../utils/libraries/EasyPosm.sol";
import {DirectionalToxicityShieldHarness} from "../harness/DirectionalToxicityShieldHarness.sol";
import {DirectionalToxicityShield} from "../../src/DirectionalToxicityShield.sol";
import {BaseTest} from "../utils/BaseTest.sol";

import {ShieldReactiveExecutor} from "../../src/reactive/ShieldReactiveExecutor.sol";
import {IDirectionalToxicityShield} from "../../src/reactive/IDirectionalToxicityShield.sol";
import {IPayable} from "reactive-lib/interfaces/IPayable.sol";
import {AbstractCallback} from "reactive-lib/base/AbstractCallback.sol";

/// @dev Mock callback proxy: acts as the AbstractPayer service provider and as
/// the address that delivers callbacks. In production the Reactive Signer posts
/// through this proxy and injects the reactive-contract address as the first
/// callback argument.
contract MockCallbackProxy is IPayable {
    receive() external payable {}

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    /// @dev Deliver a callback to the executor as if from the Reactive Signer.
    function deliver(address target, bytes calldata payload) external returns (bool, bytes memory) {
        return target.call(payload);
    }
}

/// @dev End-to-end (mocked transport) test: a Reactive callback releases stranded
/// escrow to LPs with NO swap. Proves the executor authorization model and the
/// full callback -> hook.triggerQuietDrip -> donate path.
contract ShieldReactiveExecutorTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    Currency currency0;
    Currency currency1;
    DirectionalToxicityShieldHarness hook;

    MockCallbackProxy proxy;
    ShieldReactiveExecutor executor;

    address private constant AUTHORIZED_REACTIVE = address(0xAACC);

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

        proxy = new MockCallbackProxy();
        executor = new ShieldReactiveExecutor(
            IPayable(payable(address(proxy))),
            AUTHORIZED_REACTIVE,
            IDirectionalToxicityShield(address(hook)),
            address(this)
        );
    }

    function test_executor_rejectsUnauthorizedSender() public {
        (, PoolId poolId) = _wiredPool();
        // Direct call with a wrong injected sender must revert.
        vm.expectRevert(
            abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, address(0xBAD), AUTHORIZED_REACTIVE)
        );
        executor.onQuietDrip(address(0xBAD), poolId);
    }

    function test_executor_rejectsUnregisteredPool() public {
        PoolId fake = PoolId.wrap(bytes32(uint256(0xDEAD)));
        vm.expectRevert(abi.encodeWithSelector(ShieldReactiveExecutor.PoolNotRegistered.selector, fake));
        // Authorized sender, but pool never registered.
        executor.onQuietDrip(AUTHORIZED_REACTIVE, fake);
    }

    function test_endToEnd_callbackReleasesStrandedReserveNoSwap() public {
        (, PoolId poolId) = _wiredPool();

        // Decay to quiet (no swap), leaving the reserve stranded.
        vm.roll(block.number + 10);
        vm.warp(block.timestamp + 5 minutes);
        assertEq(hook.getEffectiveRegime(poolId), 0, "pool quiet");

        uint128 reserveBefore = hook.getSmoothingReserve(poolId).reserve0;
        assertGt(reserveBefore, 0, "stranded reserve present");

        // Reactive Signer delivers the callback through the proxy. The proxy
        // injects the authorized reactive contract address as the first arg.
        bytes memory payload =
            abi.encodeWithSelector(ShieldReactiveExecutor.onQuietDrip.selector, AUTHORIZED_REACTIVE, poolId);
        (bool ok,) = proxy.deliver(address(executor), payload);
        assertTrue(ok, "callback delivery succeeded");

        uint128 reserveAfter = hook.getSmoothingReserve(poolId).reserve0;
        assertLt(reserveAfter, reserveBefore, "reserve released by reactive callback, no swap");
    }

    // ── helpers ──

    function _wiredPool() private returns (PoolKey memory key, PoolId poolId) {
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = key.toId();
        _addFullRangeLiquidity(key);
        hook.setFeePolicy(poolId, 3000, 500, 10000, 500, 10, 500, 500_000, 30, 5 minutes, 0, 5);
        hook.configureSmoothing(
            key, DirectionalToxicityShield.SmoothingConfig({enabled: true, dripBlockInterval: 5, dripBps: 2000})
        );
        hook.setReactiveExecutor(key, address(executor));
        executor.registerPool(key);

        // Build a reserve via toxic-aligned swaps.
        _swapExactIn(key, false, 1e18);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        _swapExactIn(key, false, 1e18);
        require(hook.getSmoothingReserve(poolId).reserve0 > 0, "setup: reserve not captured");
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
