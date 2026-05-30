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

/// @dev Mock callback proxy: acts as the AbstractPayer service provider and as
/// the address that delivers callbacks (the executor requires msg.sender to be
/// this proxy). In production the Reactive Signer posts through this proxy and
/// injects the reactive-contract address as the first callback argument.
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
/// escrow to LPs with NO swap. Proves the executor's two-factor authorization
/// (trusted proxy as msg.sender + registered controller as injected sender) and
/// the full callback -> hook.triggerQuietDrip -> donate path.
contract ShieldReactiveExecutorTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    Currency currency0;
    Currency currency1;
    DirectionalToxicityShieldHarness hook;

    MockCallbackProxy proxy;
    ShieldReactiveExecutor executor;

    address private constant CONTROLLER = address(0xAACC);

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
            address(proxy), IDirectionalToxicityShield(address(hook)), address(this)
        );
        executor.setController(CONTROLLER);
    }

    // ── controller wiring ──

    function test_setController_onlyOnceAndOnlyOwner() public {
        // Fresh executor with controller unset.
        ShieldReactiveExecutor fresh = new ShieldReactiveExecutor(
            address(proxy), IDirectionalToxicityShield(address(hook)), address(this)
        );
        assertEq(fresh.controller(), address(0));

        // Non-owner cannot set.
        vm.prank(address(0xBAD));
        vm.expectRevert(ShieldReactiveExecutor.NotOwner.selector);
        fresh.setController(CONTROLLER);

        // Owner sets once.
        fresh.setController(CONTROLLER);
        assertEq(fresh.controller(), CONTROLLER);

        // Cannot set twice.
        vm.expectRevert(ShieldReactiveExecutor.ControllerAlreadySet.selector);
        fresh.setController(address(0x1234));
    }

    function test_callbackRevertsWhenControllerUnset() public {
        ShieldReactiveExecutor fresh = new ShieldReactiveExecutor(
            address(proxy), IDirectionalToxicityShield(address(hook)), address(this)
        );
        PoolId fake = PoolId.wrap(bytes32(uint256(0xDEAD)));
        bytes memory payload = abi.encodeWithSelector(ShieldReactiveExecutor.onQuietDrip.selector, CONTROLLER, fake);
        // Delivered via proxy, but controller unset -> revert.
        (bool ok, bytes memory ret) = proxy.deliver(address(fresh), payload);
        assertFalse(ok, "must revert when controller unset");
        assertEq(bytes4(ret), ShieldReactiveExecutor.ControllerUnset.selector);
    }

    // ── authorization ──

    function test_rejectsDirectCallNotThroughProxy() public {
        (, PoolId poolId) = _wiredPool();
        // Direct call: msg.sender is this test contract, not the proxy.
        vm.expectRevert(abi.encodeWithSelector(ShieldReactiveExecutor.UntrustedProxy.selector, address(this)));
        executor.onQuietDrip(CONTROLLER, poolId);
    }

    function test_rejectsWrongInjectedController() public {
        (, PoolId poolId) = _wiredPool();
        // Through the proxy, but the injected sender is not the registered controller.
        bytes memory payload =
            abi.encodeWithSelector(ShieldReactiveExecutor.onQuietDrip.selector, address(0xBAD), poolId);
        (bool ok, bytes memory ret) = proxy.deliver(address(executor), payload);
        assertFalse(ok, "must reject wrong injected controller");
        assertEq(bytes4(ret), ShieldReactiveExecutor.UnauthorizedReactive.selector);
    }

    function test_rejectsUnregisteredPool() public {
        PoolId fake = PoolId.wrap(bytes32(uint256(0xDEAD)));
        bytes memory payload = abi.encodeWithSelector(ShieldReactiveExecutor.onQuietDrip.selector, CONTROLLER, fake);
        (bool ok, bytes memory ret) = proxy.deliver(address(executor), payload);
        assertFalse(ok, "must reject unregistered pool");
        assertEq(bytes4(ret), ShieldReactiveExecutor.PoolNotRegistered.selector);
    }

    // ── end-to-end ──

    function test_endToEnd_callbackReleasesStrandedReserveNoSwap() public {
        (, PoolId poolId) = _wiredPool();

        // Decay to quiet (no swap), leaving the reserve stranded.
        vm.roll(block.number + 10);
        vm.warp(block.timestamp + 5 minutes);
        assertEq(hook.getEffectiveRegime(poolId), 0, "pool quiet");

        uint128 reserveBefore = hook.getSmoothingReserve(poolId).reserve0;
        assertGt(reserveBefore, 0, "stranded reserve present");

        // Reactive Signer delivers the callback through the proxy, injecting the
        // registered controller as the first argument.
        bytes memory payload = abi.encodeWithSelector(ShieldReactiveExecutor.onQuietDrip.selector, CONTROLLER, poolId);
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
