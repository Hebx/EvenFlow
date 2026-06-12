// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
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
import {BaseTest} from "../utils/BaseTest.sol";
import {DirectionalToxicityShieldHarness} from "../harness/DirectionalToxicityShieldHarness.sol";
import {DirectionalToxicityShield} from "../../src/DirectionalToxicityShield.sol";
import {ShieldInvariantHandler} from "./ShieldInvariantHandler.sol";

/// @notice Property/invariant suite for the smoothing custody + accounting surface.
///
/// These are the protocol's *master safety properties* — the ones the Solodit
/// prior-art threat map flagged as highest risk (donate/escrow conservation). They
/// are checked after every randomized action sequence the handler produces.
///
/// Key invariant: the escrowed reserve the hook reports MUST be fully backed by
/// real ERC-6909 claims the hook holds in the PoolManager. If capture ever credits
/// the reserve without taking matching claims (or drip ever burns claims without
/// debiting the reserve), this breaks — that's value created or destroyed from
/// thin air.
contract DirectionalToxicityShieldInvariant is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    DirectionalToxicityShieldHarness internal hook;
    ShieldInvariantHandler internal handler;

    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal key;
    PoolId internal poolId;

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

        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = key.toId();

        _initializePoolWithFullRangeLiquidity(key);
        // Disable the liquidity floor so pressure-driven fees (and thus capture)
        // can activate at test liquidity levels.
        hook.setFeePolicy(poolId, 3000, 500, 10000, 500, 10, 500, 500_000, 30, 5 minutes, 0, 5);
        // Opt into smoothing so the capture/drip custody path is live.
        hook.configureSmoothing(
            key, DirectionalToxicityShield.SmoothingConfig({enabled: true, dripBlockInterval: 5, dripBps: 2000})
        );

        handler = new ShieldInvariantHandler(hook, swapRouter, key, currency0, currency1);

        // Fund the handler and approve the router so it can actually swap.
        _fundAndApprove(address(handler));

        // Only fuzz the handler's action functions.
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = ShieldInvariantHandler.swap.selector;
        selectors[1] = ShieldInvariantHandler.setPressure.selector;
        selectors[2] = ShieldInvariantHandler.warp.selector;
        selectors[3] = ShieldInvariantHandler.quietThenSwap.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ─── INVARIANTS ───────────────────────────────────────────────────────────

    /// MASTER: reported reserve is fully backed by ERC-6909 claims the hook holds
    /// in the PoolManager. No phantom escrow, no unbacked drip.
    function invariant_reserveBackedByClaims() public view {
        DirectionalToxicityShield.SmoothingReserve memory r = hook.getSmoothingReserve(poolId);
        uint256 claims0 = poolManager.balanceOf(address(hook), currency0.toId());
        uint256 claims1 = poolManager.balanceOf(address(hook), currency1.toId());
        assertGe(claims0, r.reserve0, "reserve0 not fully backed by ERC-6909 claims");
        assertGe(claims1, r.reserve1, "reserve1 not fully backed by ERC-6909 claims");
    }

    /// Conservation: cumulative captured >= cumulative dripped on each side. The
    /// hook can never release more than it ever escrowed.
    function invariant_neverDripMoreThanCaptured() public view {
        assertGe(handler.ghostCaptured0(), handler.ghostDripped0(), "dripped0 exceeds captured0");
        assertGe(handler.ghostCaptured1(), handler.ghostDripped1(), "dripped1 exceeds captured1");
    }

    /// The current reserve equals the net of cumulative capture minus drip (no
    /// leakage between the two legs). Backed claims may exceed this (rounding in
    /// the protocol's favor), but the tracked reserve must reconcile exactly.
    function invariant_reserveReconcilesWithGhosts() public view {
        DirectionalToxicityShield.SmoothingReserve memory r = hook.getSmoothingReserve(poolId);
        assertEq(
            uint256(r.reserve0), handler.ghostCaptured0() - handler.ghostDripped0(), "reserve0 != captured-dripped"
        );
        assertEq(
            uint256(r.reserve1), handler.ghostCaptured1() - handler.ghostDripped1(), "reserve1 != captured-dripped"
        );
    }

    /// The applied/last fee is always within the policy's [minFee, maxFee] band.
    /// Guards against the "fee exceeds 100%" class (Bunni finding).
    function invariant_feeWithinPolicyBounds() public view {
        DirectionalToxicityShield.FeePolicy memory p = hook.getFeePolicy(poolId);
        DirectionalToxicityShield.DirectionalState memory s = hook.getDirectionalState(poolId);
        assertLe(s.lastFee, p.maxFee, "lastFee above maxFee");
        assertGe(s.lastFee, p.minFee, "lastFee below minFee");
        assertLe(p.maxFee, LPFeeLibrary.MAX_LP_FEE, "maxFee above protocol cap");
    }

    /// Pressure is always clamped to the policy domain [-maxPressure, maxPressure].
    function invariant_pressureClamped() public view {
        DirectionalToxicityShield.FeePolicy memory p = hook.getFeePolicy(poolId);
        DirectionalToxicityShield.DirectionalState memory s = hook.getDirectionalState(poolId);
        assertLe(int256(s.pressure), int256(p.maxPressure), "pressure above maxPressure");
        assertGe(int256(s.pressure), -int256(p.maxPressure), "pressure below -maxPressure");
    }

    /// Anti-vacuity guard: after the campaign, prove the fuzzer reached the
    /// custody path so the conservation invariants aren't passing on all-zero
    /// state. NOTE: Foundry reverts handler state between runs and calls
    /// afterInvariant() against the LAST run's final state only, so we assert the
    /// coverage that is reliably hit every run (a completed swap + a capture).
    /// The drip leg's value conservation is proven deterministically in
    /// HandlerDripDiagnostic (exact dripBps release), and the safety invariants
    /// below are still checked after every call, including post-drip states that
    /// occur mid-run during the campaign.
    function afterInvariant() public view {
        assertGt(handler.swapCount(), 0, "handler never completed a swap");
        assertGt(
            handler.ghostCaptured0() + handler.ghostCaptured1(),
            0,
            "capture path never exercised - conservation invariants are vacuous"
        );
    }

    // ─── setup helpers ──────────────────────────────────────────────────────────

    function _fundAndApprove(address who) private {
        // The mock tokens were minted to this test contract in deployToken();
        // move a working balance to the handler and approve the router.
        uint256 give = 1_000_000 ether;
        currency0.transfer(who, give);
        currency1.transfer(who, give);
        vm.startPrank(who);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _initializePoolWithFullRangeLiquidity(PoolKey memory poolKey) private {
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);
        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);
        uint128 liquidityAmount = 100e18;
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
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
            a0 + 1,
            a1 + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }
}

interface IERC20Minimal {
    function approve(address spender, uint256 amount) external returns (bool);
}
