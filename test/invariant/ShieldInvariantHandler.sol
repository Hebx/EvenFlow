// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {DirectionalToxicityShieldHarness} from "../harness/DirectionalToxicityShieldHarness.sol";

/// @notice Invariant handler: drives the hook through realistic swap / pressure /
/// time / config sequences so the invariant assertions in
/// {DirectionalToxicityShieldInvariant} are checked against deep, randomized state.
///
/// The handler is the only `targetContract`. Each public function is a fuzzed
/// "action" the invariant runner can call in any order with any bounded inputs.
/// Ghost variables track cumulative captured/dripped value so conservation can be
/// checked at the suite level.
contract ShieldInvariantHandler is CommonBase, StdCheats, StdUtils {
    DirectionalToxicityShieldHarness public immutable hook;
    IUniswapV4Router04 public immutable swapRouter;
    PoolKey public key;
    PoolId public poolId;
    Currency public currency0;
    Currency public currency1;

    // ─── ghost accounting (cumulative, across the whole run) ────────────────────
    uint256 public ghostCaptured0;
    uint256 public ghostCaptured1;
    uint256 public ghostDripped0;
    uint256 public ghostDripped1;
    uint256 public swapCount;
    uint256 public dripCount;

    // Snapshot of reserve before each action, used to attribute deltas to ghosts.
    uint128 private prevReserve0;
    uint128 private prevReserve1;

    constructor(
        DirectionalToxicityShieldHarness _hook,
        IUniswapV4Router04 _swapRouter,
        PoolKey memory _key,
        Currency _c0,
        Currency _c1
    ) {
        hook = _hook;
        swapRouter = _swapRouter;
        key = _key;
        poolId = _key.toId();
        currency0 = _c0;
        currency1 = _c1;
    }

    // ─── helpers ────────────────────────────────────────────────────────────────

    function _snapshotReserve() private {
        DirectionalToxicityShieldHarness.SmoothingReserve memory r = hook.getSmoothingReserve(poolId);
        prevReserve0 = r.reserve0;
        prevReserve1 = r.reserve1;
    }

    /// Attribute the post-action reserve change to capture (grew) or drip (shrank).
    function _accountReserveDelta() private {
        DirectionalToxicityShieldHarness.SmoothingReserve memory r = hook.getSmoothingReserve(poolId);
        if (r.reserve0 > prevReserve0) ghostCaptured0 += (r.reserve0 - prevReserve0);
        else if (r.reserve0 < prevReserve0) { ghostDripped0 += (prevReserve0 - r.reserve0); dripCount++; }
        if (r.reserve1 > prevReserve1) ghostCaptured1 += (r.reserve1 - prevReserve1);
        else if (r.reserve1 < prevReserve1) ghostDripped1 += (prevReserve1 - r.reserve1);
    }

    function _safeSwap(bool zeroForOne, uint256 amountIn) private {
        _snapshotReserve();
        try swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: type(uint256).max
        }) {
            swapCount++;
            _accountReserveDelta();
        } catch {
            // A reverted swap (e.g. price limit / liquidity edge) must not corrupt
            // invariant state; we simply skip it. The invariant still holds on the
            // unchanged state.
        }
    }

    // ─── fuzzed actions ──────────────────────────────────────────────────────────

    /// Swap with a bounded size and a random direction.
    function swap(bool zeroForOne, uint256 amountIn) external {
        amountIn = bound(amountIn, 1e15, 5e18);
        _safeSwap(zeroForOne, amountIn);
    }

    /// Bias directional pressure (simulates sustained toxic/counter flow) so the
    /// capture path activates. Bounded to the policy's pressure domain.
    function setPressure(int256 p) external {
        int56 pressure = int56(bound(p, -500, 500));
        hook.setPressure(poolId, pressure);
    }

    /// Advance blocks + time so cooldowns elapse and decay engages.
    function warp(uint256 blocks, uint256 secs) external {
        blocks = bound(blocks, 1, 20);
        secs = bound(secs, 1, 10 minutes);
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + secs);
    }

    /// Force a quiet regime then swap, exercising the drip path explicitly.
    /// Self-bootstrapping: if the reserve is empty, first run a capture leg so a
    /// drip can actually fire. This keeps the capture->drip cycle reliably
    /// reachable within a single fuzz run (Foundry reverts handler state between
    /// runs, so the drip path must be hit inside one sequence, not in aggregate).
    function quietThenSwap(uint256 amountIn) external {
        amountIn = bound(amountIn, 1e15, 2e18);

        DirectionalToxicityShieldHarness.SmoothingReserve memory r = hook.getSmoothingReserve(poolId);
        if (r.reserve0 == 0 && r.reserve1 == 0) {
            // Capture leg: positive pressure + an aligned (zeroForOne=false) swap
            // escrows premium into the reserve.
            hook.setPressure(poolId, 200);
            _safeSwap(false, 1e18);
        }

        // Quiet + advance past the drip cooldown and the decay window, then a
        // small swap triggers the drip.
        hook.setPressure(poolId, 0);
        vm.roll(block.number + 6);
        vm.warp(block.timestamp + 6 minutes);
        _safeSwap(true, amountIn);
    }
}
