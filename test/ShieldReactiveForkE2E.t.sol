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
import {ShieldReactiveExecutor} from "../src/reactive/ShieldReactiveExecutor.sol";
import {IDirectionalToxicityShield} from "../src/reactive/IDirectionalToxicityShield.sol";
import {IPayable} from "reactive-lib/interfaces/IPayable.sol";

/// @notice Fork-gated end-to-end proof of the Reactive drip path against the
/// REAL Base Sepolia callback proxy address. This is the rung between the
/// fully-mocked local e2e (ShieldReactiveExecutorTest) and a live testnet
/// deployment that actually spends lREACT.
///
/// What this proves on a real fork:
///  - Our hook deploys with mined CREATE2 flags against canonical Base Sepolia
///    v4 contracts and runs the capture path.
///  - The executor's two-factor auth accepts a callback whose `msg.sender` is
///    the ACTUAL on-chain callback proxy (0xa6eA...A5a6), not a mock. We reach
///    that by `vm.prank`-ing the real proxy address (it exists in fork state).
///  - A stranded reserve (built, then decayed to quiet with no swap) is released
///    to in-range LPs purely by the reactive callback.
///
/// Skips on the local 31337 chain; run with:
///   forge test --fork-url "$BASE_SEPOLIA_RPC_URL" \
///     --match-path test/ShieldReactiveForkE2E.t.sol -vv
contract ShieldReactiveForkE2ETest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    /// Real Base Sepolia (84532) Reactive callback proxy (verified primary source).
    address private constant BASE_SEPOLIA_CALLBACK_PROXY = 0xa6eA49Ed671B8a4dfCDd34E36b7a75Ac79B8A5a6;
    uint256 private constant BASE_SEPOLIA = 84532;

    address private constant CONTROLLER = address(0xC047701123);
    /// @dev rvm_id of the Lasna reactive contract used as injected sender. The
    /// callback proxy injects this EOA, not the controller contract address.
    address private constant CONTROLLER_RVM_ID = address(0xC047701124);

    DirectionalToxicityShield private hook;
    ShieldReactiveExecutor private executor;
    Currency private currency0;
    Currency private currency1;

    function setUp() public {
        if (block.chainid != BASE_SEPOLIA) return; // configured in tests via skip
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        hook = _deployHook();
        executor = new ShieldReactiveExecutor(
            BASE_SEPOLIA_CALLBACK_PROXY, IDirectionalToxicityShield(address(hook)), address(this)
        );
        executor.setController(CONTROLLER, CONTROLLER_RVM_ID);
    }

    function test_forkE2E_realProxyCallbackReleasesStrandedReserveNoSwap() public {
        if (block.chainid != BASE_SEPOLIA) {
            vm.skip(true);
            return;
        }

        // Sanity: the real callback proxy must exist in fork state.
        assertGt(BASE_SEPOLIA_CALLBACK_PROXY.code.length, 0, "real callback proxy missing on fork");

        PoolKey memory key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = key.toId();
        _initializePoolWithFullRangeLiquidity(key);

        // Disable liquidity floor + enable smoothing + wire the executor.
        hook.configureSmoothing(
            key, DirectionalToxicityShield.SmoothingConfig({enabled: true, dripBlockInterval: 5, dripBps: 2000})
        );
        hook.setReactiveExecutor(key, address(executor));
        executor.registerPool(key);

        // Build a reserve with toxic-aligned swaps.
        _swapExactIn(key, false, 1e18);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        _swapExactIn(key, false, 1e18);

        uint128 reserveBefore = hook.getSmoothingReserve(poolId).reserve0;
        assertGt(reserveBefore, 0, "reserve captured from toxic flow");

        // Decay to quiet WITHOUT a swap -> reserve is stranded.
        vm.roll(block.number + 10);
        vm.warp(block.timestamp + 5 minutes);
        assertEq(hook.getEffectiveRegime(poolId), 0, "pool decayed to quiet");

        // The Reactive Signer posts the callback THROUGH the real proxy. We
        // emulate the transport by pranking the real proxy as msg.sender and
        // injecting the registered controller's rvm_id as the first argument,
        // exactly as requestCallbackV_1_0 will on live testnet.
        vm.prank(BASE_SEPOLIA_CALLBACK_PROXY);
        executor.onQuietDrip(CONTROLLER_RVM_ID, poolId);

        uint128 reserveAfter = hook.getSmoothingReserve(poolId).reserve0;
        assertLt(reserveAfter, reserveBefore, "stranded reserve released by real-proxy callback, no swap");

        // Released exactly dripBps (20%) of the pre-drip reserve.
        uint128 expectedRelease = uint128((uint256(reserveBefore) * 2000) / 10_000);
        assertEq(reserveBefore - reserveAfter, expectedRelease, "released exact dripBps fraction");
    }

    /// Negative control on the fork: a callback NOT routed through the real proxy
    /// is rejected by the executor's two-factor auth.
    function test_forkE2E_directCallNotThroughRealProxyReverts() public {
        if (block.chainid != BASE_SEPOLIA) {
            vm.skip(true);
            return;
        }
        PoolKey memory key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId poolId = key.toId();
        _initializePoolWithFullRangeLiquidity(key);
        hook.setReactiveExecutor(key, address(executor));
        executor.registerPool(key);

        // Caller is this test, not the proxy -> UntrustedProxy.
        vm.expectRevert(abi.encodeWithSelector(ShieldReactiveExecutor.UntrustedProxy.selector, address(this)));
        executor.onQuietDrip(CONTROLLER_RVM_ID, poolId);
    }

    // ── helpers ──

    function _deployHook() private returns (DirectionalToxicityShield deployedHook) {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory args = abi.encode(poolManager);
        (address addr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(DirectionalToxicityShield).creationCode, args);
        deployedHook = new DirectionalToxicityShield{salt: salt}(poolManager);
        assertEq(address(deployedHook), addr, "hook address mismatch");
    }

    function _initializePoolWithFullRangeLiquidity(PoolKey memory key) private {
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
