# Directional Toxicity Shield — Positioning & Go-To-Market

*Status: draft for review. All performance claims trace to tests in this repo.*

## One-liner

A Uniswap v4 hook that prices swap **toxicity by direction** — it raises LP fees when flow keeps pushing price the same way, discounts the counter-flow that rebalances the pool, and decays back to baseline when things go quiet. No oracle, no admin price feed, bounded by construction.

## The problem

Passive AMM LPs lose to informed/directional flow (LVR — loss-versus-rebalancing). The market's answers so far:

- **Static fee tiers** (incl. live production hooks like Clanker's static-fee hook on Base): one fixed fee per direction. Simple, but it can't tell a toxic run from healthy two-sided volume. It over-charges benign flow and under-charges sustained adverse flow.
- **Volatility / size dynamic fees**: react to *how big* or *how volatile*, not *which direction* the damage runs. They tax both sides of a mean-reverting market equally.
- **Nezlobin-style directional skew** (JDS, Regis, InfHook): right idea — skew by direction — but in practice these variants can ignore tick sign, hold stale elevated fees with no decay, or need oracle/liquidity tuning to behave.

## What the Shield does differently

It tracks a signed, decaying **directional pressure** per pool:

- Continue the toxic direction → fee steps up (bounded).
- Trade the counter-direction → fee discounts below base, actively rewarding rebalancers.
- Quiet period → pressure decays, fee returns to base.
- Low liquidity / thin pools → conservative fallback.

It's local, deterministic, and bounded — no external oracle dependency, every fee move clamped per pool.

## Proof points (reproducible in-repo)

From `test/PriorArtComparison.t.sol` (real bytecode of Shield + 4 prior-art hooks, identical swap traces) and `test/DirectionalToxicityShieldMainnetComparison.t.sol` (Base mainnet fork vs the live Clanker hook):

**Adaptive vs static, identical flow** (Stage 4):

| Phase | Shield | Static-fee hook |
|---|---|---|
| Sustained toxic flow | 3000 → 3500 bps-units (escalates) | fixed (e.g. 10000) |
| Counter-flow swap | 2500 (discount below base) | fixed (e.g. 5000) |
| After quiet period | decays to 3000 | unchanged |

**Vs Nezlobin-style prior art** (same-flow scenarios):

- *Counter-flow*: Shield discounts to 2500 while JDS/InfHook/VPIN stay flat at 3000 and Regis only trims to ~2559 — the Shield is the one that actively rewards rebalancing flow.
- *Toxic-then-quiet*: Shield decays back to 3000; JDS spikes to 6000 and InfHook to 4767 on the next swap because they retain/over-correct without proper decay.

**Backtest fee totals** (deterministic synthetic replay, `script/DirectionalToxicityShieldBacktest.s.sol`): across adverse-trend / mean-reversion / quiet-after-toxic scenarios the Shield lands close to the static baseline on benign flow while charging more only when pressure is real — vs detox-oracle and VPIN models that overcharge broadly (e.g. adverse-trend: shield 20,240 vs VPIN 53,000 vs detox 51,600, static 18,000).

> Honesty note for any public claim: these are model/same-flow comparisons and a live-infra fork test, not a live capital A/B on mainnet. We say exactly that. The strongest current claim is "runs against the real canonical v4 PoolManager that production hooks use, with reproducible behavioral differences" — not "earns X% more for LPs in production."

## Who it's for

- **New v4 pool deployers / launchpads** who want LP-protective fees without running an oracle.
- **LP-focused vaults / ALM managers** seeking directional-flow protection as a building block.
- **Long-tail & volatile pairs** where directional toxicity and thin liquidity hurt most.

## Differentiated, defensible positioning

"Directional toxicity pricing, oracle-free and bounded." The opt-in yield-smoothing layer (capture toxicity premium in toxic regimes, drip back to in-range LPs when quiet) is a second, separable wedge for managers who want smoother realized LP yield.

## Channels & motions

1. **Developer-first**: clean repo, reproducible benchmarks, the Stage 4 "fork vs live hook" test as the centerpiece. This is the credibility anchor for a technical audience.
2. **Writeup / thread**: "Static fees can't tell a toxic run from healthy volume — here's a v4 hook that can," with the side-by-side fee table and a link to the one-command repro.
3. **Uniswap v4 hook directories / awesome-lists** (e.g. awesome-uniswap-hooks): submit once README + audit posture are prod-ready.
4. **Design partners**: 1–2 pool deployers or an ALM vault to run a real testnet/mainnet pool and produce the first live dataset — which upgrades every claim above from "model" to "measured."

## Honest gaps before loud marketing

- No audit yet — say "unaudited" everywhere until that changes.
- No live capital performance data — the fork test proves *mechanics against real infra*, not *realized LP PnL*.
- Custody tradeoff in the smoothing layer is real (hook briefly holds premium as ERC-6909 claims); keep it opt-in and clearly disclosed.

## Suggested next step

Stand up one live testnet pool with a scripted toxic-flow demo and capture the fee timeline as the first "real pool, real PoolManager" artifact. That single dataset is worth more than any amount of copy.
