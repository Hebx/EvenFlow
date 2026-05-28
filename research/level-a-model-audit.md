# Level A: Model Audit — Prior-Art Source vs Our Backtest/Simulation Models

Date: 2026-05-27
Auditor: Kiro (automated source review)

This document compares the actual source code of each prior-art hook against the modeled comparator in our `DirectionalToxicityShieldSimulation.s.sol` and `DirectionalToxicityShieldBacktest.s.sol`. The goal is to identify fidelity gaps between our models and the real implementations.

---

## 1. JDS AsymmetricFeesHook (`Jds-23/asymmetric-fees-hook`)

### Real mechanism (TheHook.sol, 149 lines)
- Uses **sqrtPriceX96 delta** (not tick delta) as the price-movement signal.
- `MULTIPLIER = 7500`, `MULTIPLIER_DIVISOR = 1_000_000` → fee adjustment = `7500 * sqrtPriceDelta / 1_000_000`.
- Updates only **once per block** (`poolToLastUpdatedBN`).
- Stores `poolToCurrentFeeDelta` (uint24) and `poolToCurrentFeeDeltaSign` (int8).
- Direction logic: if `zeroForOne` and sign is `-1` → premium; if sign is `1` → discount. Vice versa for `!zeroForOne`.
- No min/max fee clamp. Fee can underflow to 0 (uint24 subtraction without guard).
- No decay, no accumulation, no liquidity guard.

### Our model (`_jdsAsymmetricFee` in Simulation)
- Uses **tick delta** with `NEZLOBIN_C=750 / NEZLOBIN_SCALE=1000` → `tickDelta * 750 / 1000`.
- Comment says "normalized model maps the same previous-move idea onto tick movement."

### Fidelity gaps

| Aspect | Real | Our model | Impact |
|--------|------|-----------|--------|
| **Price signal** | sqrtPriceX96 delta | Tick delta | **HIGH** — sqrtPrice and tick are non-linearly related. For small moves near tick 0, 1 tick ≈ 1 bip of price, but sqrtPriceX96 delta for 20 ticks is ~0.1% of sqrtPrice, yielding a fee delta of ~12 bps via their formula. Our model gives `20*750/1000 = 15` bps. Close but not identical. |
| **Update frequency** | Once per block | Every step | LOW — our simulation uses 12s steps which approximates 1 block. |
| **Underflow guard** | None (can produce 0 fee) | We clamp at 0 | LOW — edge case only. |
| **Accumulation** | None — overwrites each block | None — matches | OK |
| **Decay** | None | None | OK |

### Verdict: Model is **directionally correct** but uses a linear tick proxy for a sqrtPrice-based formula. For the tick ranges in our scenarios (20-28 ticks), the error is ~20% on the fee delta magnitude. This means our model slightly overstates JDS fee responsiveness.

---

## 2. RegisGraptin Nezlobin Hook (`RegisGraptin/Uniswap-Nezlobin-Hook`)

### Real mechanism (NezlobinHook.sol, 175 lines)
- Uses **tick delta** (`currentTick - lastTicks[poolId]`).
- `C = 750`, `SCALE = 1000` → `deltaFee = abs(tickDelta) * 750 / 1000`.
- Direction: `zeroForOne` → discount (baseFee - deltaFee); `!zeroForOne` → premium (baseFee + deltaFee).
- Clamps: min at `MIN_FEE=500`, max at `MAX_FEE=50_000`.
- Updates tick **once per block** (timestamp check).
- Uses `poolManager.updateDynamicLPFee()` (pool-level fee update, not per-swap override).
- **Critical:** direction is determined by `zeroForOne` alone, NOT by the sign of tickDelta. This means it always charges more for `!zeroForOne` regardless of which direction price moved.

### Our model (`_regisNezlobinFee` in Simulation)
- Same formula: `abs(tickDelta) * 750 / 1000`.
- Same direction logic: `zeroForOne` → discount, `!zeroForOne` → premium.
- Same min/max clamps (500 / 50_000).

### Fidelity gaps

| Aspect | Real | Our model | Impact |
|--------|------|-----------|--------|
| **Fee application** | `updateDynamicLPFee` (pool-level, persists) | Per-step calculation | LOW — in single-swap-per-block scenarios, equivalent. |
| **Direction logic** | Based on `zeroForOne` only (ignores tick sign) | Same | OK — **this is a design flaw in their hook** that we correctly model. |
| **Tick source** | Pre-swap current tick | Previous step's tick move | OK — equivalent for sequential replay. |

### Verdict: Model is **highly faithful**. The Regis hook has a design flaw (direction doesn't depend on price movement direction), and we correctly capture it.

---

## 3. InfHook Nezlobin (`emrhncvsgl/InfHook`)

### Real mechanism (Nezlobin.sol, 134 lines)
- Uses **tick delta** with a peculiar formula: `c = (750 * 3000) / (tickDelta * 1000)` then `beta = c * tickDelta`.
- Algebraically: `beta = (750 * 3000) / 1000 = 2250` — **beta is constant regardless of tickDelta!**
- Direction: `!zeroForOne` → premium (baseFee + beta = 5250); `zeroForOne` → discount (baseFee - beta = 750, or MIN_FEE=500 if beta > baseFee).
- Updates only when `block.timestamp - poolToTimeStamp > 1`.
- Uses `poolManager.updateDynamicLPFee()` (persists until next update).
- **Critical bug:** the formula cancels out tickDelta, making the fee adjustment constant at 2250 bps whenever any non-zero tick movement occurs.

### Our model (`_infHookNezlobinFee` in Simulation)
- Replicates the exact formula: `c = (750 * 3000) / (tickDelta * 1000)`, `beta = c * tickDelta`.
- Correctly produces the constant beta behavior.
- Stateful: carries `currentFee` forward (matches `updateDynamicLPFee` persistence).

### Fidelity gaps

| Aspect | Real | Our model | Impact |
|--------|------|-----------|--------|
| **Constant beta** | Yes (2250 always) | Yes | OK |
| **Statefulness** | Fee persists via pool update | Carried as `currentFee` | OK |
| **Zero-delta guard** | Returns early, fee unchanged | Same | OK |

### Verdict: Model is **exact**. We correctly capture the algebraic bug that makes this hook produce a fixed fee skew.

---

## 4. Jaseempk NZ-Directional-Fee (`Jaseempk/NZ-Directional-Fee`)

### Real mechanism (NezlobinDirectionalFee.sol, 284 lines)
- Uses **sqrtPriceX96 delta** as price impact: `priceImpactPercent = (ethPriceT1 - ethPriceT) * 1e4 / ethPriceT`.
- Threshold-gated: only adjusts if `priceImpactPercent >= buyThreshold (2e4)` or `<= sellThreshold (-2e4)`.
- `cDelta = alpha * priceImpact / liquidity` (with precision scaling), capped so fee stays > 0.
- **Depends on Chainlink oracle** (`AggregatorV3Interface`) — but actually uses sqrtPriceX96 from pool, not the oracle feed (oracle is declared but unused in fee logic).
- **Owner-controlled** thresholds (`updateBuyThreshold`, `updateSellThreshold`, `updateAlpha`).
- Uses `poolManager.updateDynamicLPFee()` (persists).
- Direction: `isToken0PricePumping` + `zeroForOne` determines premium/discount.
- Initial fee: 1000 (0.1%).

### Our model (`_jaseempkThresholdFee` in Simulation)
- Tick-normalized: threshold at 20 ticks (approximating their 2% sqrtPrice threshold).
- `cDelta = abs(tickMove) * 10`, capped at 500.
- Stateful: carries `currentFee` forward.
- Same direction logic.

### Fidelity gaps

| Aspect | Real | Our model | Impact |
|--------|------|-----------|--------|
| **Price signal** | sqrtPriceX96 percentage change | Tick delta with fixed multiplier | MEDIUM — their formula is liquidity-dependent and percentage-based. Our linear tick model is a simplification. |
| **Threshold** | 2% sqrtPrice change | 20 ticks (~2% near tick 0) | LOW — reasonable approximation. |
| **Liquidity dependence** | `cDelta` scales inversely with liquidity | Fixed multiplier | MEDIUM — in low-liquidity pools their hook is more aggressive. Our model uses a constant. |
| **Initial fee** | 1000 | 1000 | OK |
| **Oracle** | Declared but unused in fee path | Not modeled | OK — no impact. |

### Verdict: Model is **directionally correct** but simplifies the liquidity-dependent cDelta calculation. For our fixed-liquidity scenarios this is acceptable, but the model would diverge in variable-liquidity replays.

---

## 5. Anti-Toxicity Hook / NonToxicPool (`Elli610/non-IL-hook`)

### Real mechanism (NonToxicPool.sol + NonToxicMath.sol, 592 lines total)
- **Much more complex than a fee-only hook.** It is a full managed-liquidity vault (ERC20 shares, deposit/withdraw, wide+narrow positions, rebalancing).
- Fee formula in `computeFees()`:
  - `fee = alpha * (volumeImpact + historyPremium) / currentSqrtPrice`
  - `volumeImpact = |volume1| * SCALE² / (2 * activeLiq)`
  - `historyPremium = SCALE * sqrtPriceHistory`
  - `sqrtPriceHistory` depends on whether swap is in-trend or counter-trend (uses initial/extremum price tracking).
- **Instantaneous** — no time-based decay, no accumulation. Computed fresh each swap.
- **Volume-dependent** — larger swaps pay more.
- **Price-history-dependent** — swaps continuing a trend pay more than counter-trend swaps.
- Rebalances positions when drawback exceeds 0.9% from extremum.
- Uses `updateDynamicLPFee()` (pool-level).

### Our model (`_antiToxicityFee` in Backtest)
- Uses a simplified directional imbalance accumulator.
- `adjustment = imbalanceAbs * 12 + notional * 1000 / activeLiquidity`, capped at 2000.
- Imbalance resets on direction change (simplified version of their extremum tracking).

### Fidelity gaps

| Aspect | Real | Our model | Impact |
|--------|------|-----------|--------|
| **Fee formula** | `alpha * (volume/2L + priceHistory) / sqrtPrice` | Linear imbalance + size | **HIGH** — completely different mathematical structure. |
| **Volume dependence** | Quadratic (volume² effect via volume/liquidity) | Linear (notional/liquidity) | MEDIUM |
| **Price history** | Tracks initial/extremum sqrtPrice, uses distance | Tracks signed imbalance | HIGH — different state model. |
| **Decay** | None (resets on rebalance trigger) | Resets on direction change | MEDIUM — different reset trigger. |
| **Managed liquidity** | Full vault with rebalancing | Not modeled | HIGH — their hook's LP outcome includes rebalancing gains, not just fee capture. |
| **Instantaneous vs accumulated** | Fresh each swap | Accumulated state | HIGH |

### Verdict: Model is a **rough directional approximation** only. The real NonToxicPool is fundamentally different — it's a managed vault with instantaneous volume+history fees, not a pressure accumulator. Our model captures the "toxic flow pays more" behavior qualitatively but not quantitatively. **This is the weakest model in our comparison.**

---

## 6. VPIN Dynamic Fee Hook (`mishoko/uniswap-hooks-capstone-mishoko`)

### Real mechanism (VPINDynamicFeeHook.sol, 228 lines)
- Two-layer fee:
  1. **VPIN base fee**: `baseFee + (maxFee - baseFee) * vpin / 1e18` where VPIN is computed from volume buckets.
  2. **Nezlobin directional adjustment**: `fee * |tickDelta| / 10000`, capped at 50% of fee.
- VPIN accumulation: tracks buy/sell volume in fixed-size buckets. `lastVPIN` updates when a bucket cycle completes.
- Direction: `(tickDelta > 0 && !zeroForOne) || (tickDelta < 0 && zeroForOne)` = aligned with momentum → premium.
- Uses `OVERRIDE_FEE_FLAG` (per-swap override, like Shield).
- Updates tick once per block in `afterSwap`.

### Our model (`_vpinFee` in Backtest)
- Simplified: `imbalance / volume` as VPIN proxy (no bucket structure).
- `toxicityFee = baseFee + (maxFee - baseFee) * vpin / 1e18`.
- Directional adjustment: flat ±250 bps based on alignment (not proportional to tickDelta or fee).

### Fidelity gaps

| Aspect | Real | Our model | Impact |
|--------|------|-----------|--------|
| **VPIN calculation** | Fixed-size volume buckets, rolling window | Running imbalance/volume ratio | MEDIUM — bucket structure creates lag and smoothing that our model lacks. |
| **Directional adjustment** | Proportional to `fee * |tickDelta| / 10000`, capped at 50% | Flat ±250 bps | **HIGH** — their adjustment scales with both the base fee level AND tick movement magnitude. |
| **Fee delivery** | Per-swap override (OVERRIDE_FEE_FLAG) | Per-step calculation | OK — equivalent in replay. |
| **Bucket lag** | VPIN only updates after full bucket cycle | Instant | MEDIUM — real hook has cold-start period where VPIN=0. |

### Verdict: Model captures the **two-layer structure** (toxicity base + directional skew) but simplifies both layers. The flat ±250 directional adjustment is the biggest gap — the real hook's adjustment is multiplicative and tick-proportional.

---

## Summary Table

| Hook | Model fidelity | Key gap | Risk to our claims |
|------|---------------|---------|-------------------|
| JDS AsymmetricFeesHook | Good (80%) | sqrtPrice vs tick proxy | Low — our model slightly overstates their responsiveness |
| RegisGraptin Nezlobin | Excellent (95%) | Pool-level fee persistence | Negligible |
| InfHook Nezlobin | Exact (100%) | None | None |
| Jaseempk NZ-Directional | Good (75%) | Liquidity-dependent cDelta | Low — fixed-liquidity scenarios mask the gap |
| Anti-Toxicity Hook | Rough (40%) | Completely different architecture (vault + instantaneous fees) | **HIGH** — we should not claim quantitative superiority over this hook based on our model |
| VPIN Hook | Moderate (60%) | Bucket structure + multiplicative directional adjustment | Medium — our model understates their directional responsiveness |

---

## Recommendations

1. **Anti-Toxicity Hook:** Add a disclaimer that our model is a qualitative approximation. For Level B, deploy their actual contract and compare real bytecode behavior.
2. **JDS:** Consider adding a sqrtPrice-based variant to the simulation for higher fidelity, or document the tick-proxy limitation.
3. **VPIN:** Update the directional adjustment model to be proportional (`fee * |tickDelta| / 10000`) rather than flat ±250.
4. **All models:** Add a "model fidelity" column to `research/dynamic-fee-prize-comparison.md` so readers know which comparisons are high-confidence vs approximate.

---

## Next: Level B

Build a unified Foundry fork-test that deploys real bytecode of each hook (where compatible with current v4-core), pushes identical swap traces, and compares actual fee behavior side-by-side. This eliminates model fidelity concerns entirely for hooks that compile against our v4 dependency version.
