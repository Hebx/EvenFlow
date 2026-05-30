# Design Draft — Toxicity-Funded LP Yield Smoothing

> **STATUS: APPROVED 2026-05-30 (Hebx) — custody accepted, opt-in per pool.**
> Build proceeds as the phased TDD plan. This introduces value custody into the
> hook (a real change to our risk/audit story); the opt-in default keeps the
> base product unchanged for pools that don't configure smoothing.
>
> **Ownership model (decided):** init `hookData` is unavailable in this v4
> version, so the pool *configurer* is captured as the `sender` that called
> `poolManager.initialize`. Only that address may call `configureSmoothing`.
> Limitation: if a pool is initialized via a router/PositionManager, that
> contract becomes the configurer. Documented; initialize directly to retain
> control.

**Author:** Kiro · **Date:** 2026-05-30 · **Repo:** `directional-toxicity-shield`

---

## Why this exists

UHI9's theme is **Impermanent Loss and Yield Systems**. Our hook scores 5/5 on
the IL half (directional toxicity fee shields LPs from informed/aligned flow)
but only 3/5 on the Yield half — today there is no explicit "yield system,"
just a dynamic LP fee. This draft closes that gap.

The mechanism reuses what the hook already produces. We currently surcharge
aligned/toxic flow (fee rises `baseFee` → up to `baseFee + maxFeeStep`, i.e.
3000 → 3500 in the default policy) and discount counter-flow. That surcharge is
the **toxicity premium**. Right now it flows straight through normal v4 LP fee
accounting, so LP revenue is *spiky*: large during toxic regimes, thin during
quiet ones. Spiky yield is bad LP UX, makes APR impossible to advertise, and
drives mercenary add/remove churn.

**The idea:** divert the toxicity premium into a hook-held reserve during toxic
regimes, then drip it back to in-range LPs during quiet regimes via
`poolManager.donate()`. This turns a spiky fee stream into a smoothed yield
stream — a yield system built directly on the toxicity signal we already
compute. Toxic flow subsidizes quiet-period LP returns.

---

## Two angles considered

**Angle A — Instant rebate (rejected as the headline).** Capture the surcharge
in `afterSwap` and immediately `donate()` it to in-range LPs in the same swap.
Problem: this is economically almost identical to just leaving it as an LP fee
(both credit currently-in-range liquidity). It adds custody risk and gas for
near-zero differentiation. Not worth it on its own.

**Angle B — Temporal smoothing (recommended).** Escrow the surcharge during
toxic regimes (regime 1/2), drip it out during quiet regimes (regime 0). This
is the only version that delivers a genuine *yield system*: it moves value
across time, which requires the hook to hold value briefly. That custody is the
core tradeoff (see Decision points).

Key honest finding: **true smoothing implies custody.** There is no
no-custody trick that moves value from toxic periods to quiet periods — instant
donate-through gives no smoothing, and pure fee-rate modulation just changes who
pays without building a reserve. If we want the yield-smoothing story, we accept
the hook holding ERC-6909 claims between capture and drip.

---

## Mechanism (recommended design)

Current `_beforeSwap` sets the directional fee (base ± adjustment) and that
entire fee goes to LPs immediately. We split that into a predictable base plus a
diverted premium:

1. **`_beforeSwap`** — set the applied LP fee to **`baseFee` only** (LPs always
   get a predictable base). The counter-flow *discount* stays here as a fee
   reduction below base (it attracts rebalancing flow; not reserve-funded).
2. **`_afterSwap`** (toxic regime, aligned flow) — compute the premium that the
   old design would have charged (`directionalFee − baseFee`) applied to swap
   size, and `take()` it as ERC-6909 claims into a per-pool, per-currency
   **smoothing reserve**. Returned as a positive `afterSwapReturnDelta` on the
   unspecified currency (the proven `BaseDynamicAfterFee` path).
3. **`_afterSwap`** (quiet regime, regime 0) — `donate()` a bounded slice of the
   reserve to in-range LPs, rate-limited (e.g. at most once per N blocks and a
   capped fraction per drip) so yield is smoothed, not dumped.

Net effect: LP yield ≈ base fees + smoothed drip − discounts given. The toxic
premium is time-shifted from spike to stream.

### State (additive; preserves current layout)

```solidity
struct SmoothingReserve {     // new mapping: poolId => reserve
    uint128 reserve0;         // ERC-6909 claims held in currency0
    uint128 reserve1;         // ERC-6909 claims held in currency1
    uint40  lastDripBlock;    // rate-limit drips
}
mapping(PoolId => SmoothingReserve) internal smoothingReserves;
```

`FeePolicy` gains a few smoothing knobs (all invariant-checked by the existing
`_validatePolicy`), e.g. `dripBlockInterval`, `dripBps` (max fraction of reserve
released per drip), and a `smoothingEnabled` flag so pools can opt out and keep
the pure-fee behavior.

### Hook permissions delta

```
afterSwapReturnDelta: false -> true     // required to skim the premium
beforeSwap / afterSwap: unchanged (already true)
```

This changes the mined hook address (new flags), so it's a fresh deploy on both
testnets — consistent with our "redeploy on contract change" rule.

---

## Feasibility — confirmed against pinned libs

- `IPoolManager.donate(key, amount0, amount1, hookData)` — present
  (`...v4-core/src/interfaces/IPoolManager.sol`), used by `LiquidityPenaltyHook`.
- `CurrencySettler.take/settle(poolManager, addr, amount, true)` — present,
  mints/burns ERC-6909 claims; this is how `BaseDynamicAfterFee` and
  `LiquidityPenaltyHook` hold and release value.
- `afterSwapReturnDelta` returning a positive `int128` to skim the unspecified
  currency — implemented end-to-end in `BaseDynamicAfterFee._afterSwap`.

No v4-core upgrade required. (Contrast with the Task 2 `hookData`-on-init item,
which *is* blocked by this version.)

---

## Risks / tradeoffs (honest)

1. **Custody.** Biggest one. We move from a pure, stateless fee hook to a
   value-custodying hook. That expands the audit surface: settlement
   correctness, reentrancy around `take`/`donate`, and the ERC-6909 accounting
   must be exact or LP funds can be stranded. This is the thing to weigh.
2. **Drip targets current in-range LPs, not the ones who ate the toxicity.**
   `donate()` credits whoever is in range at drip time. Acceptable for
   *pool-level* smoothing; it is not per-LP fairness. Must be stated plainly to
   integrators.
3. **`donate()` reverts with zero in-range liquidity.** Guard: skip the drip and
   retain the reserve if `getLiquidity(poolId) == 0`.
4. **Gas.** `afterSwapReturnDelta` + `take` on toxic swaps and occasional
   `donate` on quiet swaps add cost. Rate-limit drips and skip dust to bound it.
5. **Reconciling with the counter-flow discount.** Discounts are funded by LPs
   forgoing fee, not by the reserve (you can't pay a swapper a negative fee from
   escrow cleanly). Net LP yield model must show base + drip − discounts.
6. **Premium is small.** Default policy caps the surcharge at `maxFeeStep`=500
   (0.05%). So the smoothing budget is 0–0.05% of toxic-swap notional. Real but
   modest; we should size expectations in the writeup, not oversell APR.

---

## Phased build plan (TDD, one commit per task) — only if approved

1. **Reserve accounting + policy knobs.** Add `SmoothingReserve`, smoothing
   fields on `FeePolicy`, extend `_validatePolicy`. No behavior change yet.
   Tests: invariants, opt-out default keeps current fees.
2. **Premium capture.** Flip `afterSwapReturnDelta` on; in `_afterSwap` skim the
   premium on toxic aligned flow into the reserve; set `_beforeSwap` applied fee
   to base. Tests: reserve grows by exactly the old surcharge; non-toxic swaps
   unchanged; exactIn/exactOut both correct.
3. **Rate-limited drip.** On quiet-regime swaps, donate a capped reserve slice to
   in-range LPs; guard zero liquidity; respect `dripBlockInterval`. Tests:
   smoothing across a toxic→quiet sequence, zero-liquidity skip, dust skip.
4. **Re-run Level A/B comparisons + onchain Stage 1/2 gates**, update results
   docs, then redeploy both testnets per our rule.

Estimated surface: ~120–160 lines in `src/`, ~12–16 new tests.

---

## Decision points (need your call)

1. **Accept custody?** This is the gate. Smoothing requires the hook to hold
   ERC-6909 claims between capture and drip. If you want to stay "pure, no
   custody" for the safety story, we drop Angle B and instead just *document*
   that the directional fee already accrues to LPs (weaker Yield fit, stays 3/5).
2. **Smoothing on by default or opt-in per pool?** I lean opt-in
   (`smoothingEnabled=false` default) so the base product stays unchanged and
   smoothing is a feature pools choose.
3. **Scope for Hookathon 9 submission (June 11):** full build (tasks 1–4) or a
   documented design + a single capture-only proof (task 1–2) as the demo? Given
   the custody audit weight, a clean capture-only demo plus this design may be
   the stronger, lower-risk submission than a rushed full drip.
