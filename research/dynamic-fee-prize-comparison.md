# Dynamic Fee Prior-Art Comparison

Date: 2026-05-25

This note compares the Base Sepolia Stage 3 Directional Toxicity Shield run against prior dynamic-fee hooks that claim to reduce LP loss, toxic flow, or impermanent-loss exposure. Directional fees and dynamic IL protection are not novel by themselves; the Shield claim should stay narrower: a pure v4 hook with signed decaying pressure, explicit bounds, no custody, no external oracle dependency, and verified testnet behavior.

## Our Stage 3 reference run

Base Sepolia mock-token run:

- Hook: `0xdf1b6843711039408b3b87572F9E9830BCcaF0C0`
- PoolId: `0x9468fe871c2dd7581239053dc54d37466d1d2f5ad88246a39606867549aa1415`
- Flow: initialize dynamic-fee pool, add full-range liquidity, execute two same-direction swaps
- First swap fee: `3000`
- Second swap fee: `3500`
- Final pressure: `500`
- Final regime: `2`

Interpretation: the first swap is priced at the calm base fee; after pressure is observed, the next aligned swap pays a bounded higher fee. This is the core demo behavior.

## Prize and prior-art set

| Project | Source | Prize status found | Main mechanism | Comparison to Shield |
| --- | --- | --- | --- | --- |
| AsymmetricFeesHook | https://ethglobal.com/showcase/asymetricfeeshook-btttj and https://github.com/Jds-23/asymmetric-fees-hook | ETHGlobal page lists Blockscout Explorer Big Pool Prize | Nezlobin-style previous-block price movement; increase buy fee and decrease sell fee after price moves | Direct directional-fee prior art. Shield should not claim first directional fee. Shield differs by using signed pressure accumulation, decay/reset, liquidity floor, max pressure, max fee step, and testnet deployment evidence. |
| Anti-Toxicity Hook | https://ethglobal.com/showcase/anti-toxicity-hook-fxv68 and https://github.com/Elli610/non-IL-hook | ETHGlobal page lists Uniswap Foundation v4 Stable-Asset Hooks 3rd place | Cumulative directional pressure, fee discounts for counter-flow, optional LP position management | Closest product competitor. Shield is cleaner for MVP because it avoids custody/rebalance authority and keeps only fee policy in the hot path. Do not claim we are economically better until we run comparable historical backtests. |
| Dynamic AMM Fees | https://ethglobal.com/showcase/dynamic-amm-fees-x3x1v | ETHGlobal page lists Uniswap Foundation Best Use of Hook Features 1st place and PancakeSwap Creative Hook Ideas | Chainlink volatility oracle plus trade size; dynamic fee for volatility and large orders | Strong prize-winning dynamic-fee precedent, but it is volatility/size-based, not signed directional pressure. It protects LPs in volatile or large-trade conditions but does not inherently make counter-pressure swaps cheaper. |
| DetoxHook | https://ethglobal.com/showcase/detox-hook-mppeg | ETHGlobal page lists Blockscout prize, Pyth 1st place, ETHGlobal Prague 2025 finalist | Pyth oracle detects external-price arbitrage, captures part of arbitrage value, donates to LPs | Strong MEV/oracle competitor. Shield intentionally avoids external oracle dependency and donation/accounting complexity in MVP; Detox is better suited to explicit external-market arbitrage capture. |
| VPIN Dynamic Fee Hook | https://github.com/mishoko/uniswap-hooks-capstone-mishoko | No ETHGlobal prize page found in this pass | VPIN volume-bucket toxicity plus Nezlobin-style directional asymmetry | Important novelty bar. Shield is simpler and bounded; VPIN may be richer analytically but needs bucket calibration and more empirical validation. |
| RegisGraptin Nezlobin Hook | https://github.com/RegisGraptin/Uniswap-Nezlobin-Hook | No prize page found in this pass | Educational Nezlobin dynamic fee | Useful baseline, not enough for UHI9 positioning. |
| Jaseempk NZ-Directional-Fee | https://github.com/Jaseempk/NZ-Directional-Fee | No prize page found in this pass | Nezlobin directional fee with owner-tuned thresholds | Useful baseline. Shield avoids owner-driven hot-path tuning and oracle dependency in MVP. |

## Same-run behavior comparison

The exact Base Sepolia run can only be executed for contracts deployed to Base Sepolia with compatible pool setup. For competitors without a deployed Base Sepolia hook/pool, we compare the same two-swap pattern by mechanism and by our deterministic simulation models.

| Mechanism | First same-direction swap | Second same-direction swap | Counter-flow behavior | Key weakness versus Shield |
| --- | --- | --- | --- | --- |
| Static fee | `3000` | `3000` | No discount | Does not price toxic direction. |
| Plain Nezlobin / AsymmetricFeesHook style | Base fee or previous-move fee | Small direction skew from previous price move | Lower fee for opposite side | Usually last-move based; weaker stale-state, decay, liquidity, and max-step controls. |
| Anti-Toxicity Hook | Size/liquidity/imbalance responsive | Higher if it worsens imbalance | Discount for rebalancing | Very close; broader scope includes LP management, making the MVP security surface larger. |
| Dynamic AMM Fees | Based on volatility and size | Same formula unless volatility/size changes | Usually no directional discount | Does not distinguish harmful aligned flow from helpful counter-flow. |
| DetoxHook | Low if no oracle-detected external arbitrage | High if Pyth oracle shows extractive opportunity | Not primarily pressure-based | Depends on external oracle freshness/confidence and donation/accounting paths. |
| VPIN hook | Depends on bucket fill and imbalance | Higher once buckets show toxic imbalance | Nezlobin adjustment can discount counter-flow | Requires bucket/window calibration and has more state. |
| Directional Toxicity Shield | `3000` | `3500` | Lower fee when flow offsets built pressure | Current gap is historical PnL/backtest depth, not basic hook mechanics. |

## Current simulation evidence

The local simulation compares static fee, plain directional, JDS AsymmetricFeesHook-style logic, Regis Nezlobin, InfHook Nezlobin, Jaseempk threshold logic, a deployed fixed-direction Base comparator, and Shield.

Latest deterministic one-direction toxic-flow output:

- Static fees: `12000000000000000000000`
- JDS asymmetric fees: `12045000000000000000000`, max fee `3015`
- Regis NZ fees: `12045000000000000000000`, max fee `3015`
- InfHook NZ fees: `18720000000000000000000`, max fee `5240`
- Jaseempk NZ fees: `5200000000000000000000`, max fee `1600`
- Deployed fixed-direction comparator fees: `40000000000000000000000`, max fee `10000`
- Shield fees: `13200000000000000000000`, max fee `3500`, final pressure `200`

Takeaway: Shield is intentionally more responsive than thin previous-move Nezlobin examples but far less extreme than fixed 1% directional pricing. Its main strength is controlled responsiveness: bounded pressure, bounded fee step, and decay/reset behavior.

## Positioning line

Use this:

> Directional Toxicity Shield is not the first directional or anti-toxic-flow fee hook. It is a production-disciplined version of that idea: local-only signed pressure, bounded per-swap fee overrides, decay/reset controls, liquidity guards, no custody, no external oracle dependency, and verified Unichain/Base Sepolia runs.

Avoid this:

> We invented directional dynamic fees or solved impermanent loss.

## Next comparison work

- Add a historical replay/backtest harness against at least one Uniswap v3/v4 volatile pair.
- Add a VPIN bucket baseline to the Solidity simulation or a separate Python replay.
- If comparing directly against Anti-Toxicity Hook, run their repo tests and inspect their deployed/demo path rather than relying only on README claims.
- If using USDC testnet demo pools, verify the official testnet USDC address first and keep mock-token tests as the canonical mechanics proof.
