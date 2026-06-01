# Directional Toxicity Shield

> A Uniswap v4 hook that prices swap toxicity **by direction** — oracle-free, bounded, and deterministic.

[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://getfoundry.sh/)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.30-363636.svg?logo=solidity)](https://soliditylang.org/)
[![Uniswap v4](https://img.shields.io/badge/Uniswap-v4%20hook-FF007A.svg?logo=uniswap)](https://docs.uniswap.org/contracts/v4/overview)
[![Reactive Network](https://img.shields.io/badge/Reactive-autonomous%20drip-7B3FE4.svg)](https://reactive.network)
[![Tests](https://img.shields.io/badge/tests-151%20passing-3FB950.svg)](#verify)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

> **Status:** unaudited MVP. Benchmarks are reproducible same-flow model comparisons plus live-infrastructure fork tests against the real canonical v4 `PoolManager`. They show mechanics and behavioral differences, not realized LP PnL. Don't present them as production yield numbers.

---

## The problem

Passive LPs bleed to informed, one-directional flow (loss-versus-rebalancing). The usual defenses can't tell a toxic run from healthy two-sided volume:

- **Static fee tiers** charge one fixed fee — over-taxing benign flow, under-charging sustained adverse flow.
- **Volatility / size fees** react to *how big*, not *which direction* the damage runs.
- **Nezlobin-style skews** point the right way but often ignore tick sign, hold stale fees with no decay, or need an oracle.

## What the Shield does

It tracks a signed, decaying **directional pressure** per pool and moves the LP fee with it — no oracle, every move clamped:

```
  fee
   ^
3500│        ____ sustained toxic flow → escalate (bounded)
   │       /
3000│──── /─────────────── base ───────────\________ decays back when quiet
   │    /
2500│  *  ← counter-flow swap → discount below base (rewards rebalancers)
   └──────────────────────────────────────────────────────▶ swaps over time
```

- Keep pushing price one way → fee steps **up** (bounded).
- Trade the rebalancing direction → fee **discounts** below base.
- Market goes quiet → pressure decays, fee returns to base.

Pure v4: permissions are `beforeInitialize`, `afterInitialize`, `beforeSwap`, `afterSwap` (plus `afterSwapReturnDelta` only when smoothing is on).

## Three layers, opt-in

A pool runs any prefix of this stack. Each layer is independent and the lower layers never depend on the higher ones.

```
┌─ 1. Directional fee ────────────────────────────────────────────────┐
│   Signed pressure → adaptive LP fee. No custody, no oracle. Always on.│
└──────────────────────────────────────────────────────────────────────┘
        │  opt in per pool: configureSmoothing(enabled: true)
        ▼
┌─ 2. Yield smoothing ────────────────────────────────────────────────┐
│   Capture the toxicity premium in toxic regimes → drip it back to     │
│   in-range LPs in quiet regimes. Smooths realized LP yield.           │
└──────────────────────────────────────────────────────────────────────┘
        │  optional autonomous trigger
        ▼
┌─ 3. Reactive drip ──────────────────────────────────────────────────┐
│   A Reactive Network cron fires the quiet-regime drip cross-chain,    │
│   so a stranded reserve is returned to LPs even with zero swaps.      │
└──────────────────────────────────────────────────────────────────────┘
```

| Layer | Custody? | Default | Proven on |
|---|:--:|:--:|---|
| **1 · Directional fee** | none | always on | local + Base mainnet fork + live Base Sepolia |
| **2 · Yield smoothing** | opt-in (ERC-6909 claims) | off | Base mainnet fork + live Base Sepolia capture |
| **3 · Reactive drip** | none added | optional | live Base Sepolia ← Reactive Lasna |

## How it compares

| Approach | Reacts to direction? | Discounts counter-flow? | Decays when quiet? | Oracle-free? |
|---|:--:|:--:|:--:|:--:|
| Static fee tier (e.g. live Clanker hook) | per-direction, fixed | no | no | yes |
| Volatility / size dynamic fee | no | no | n/a | usually |
| Nezlobin skew (JDS / Regis / InfHook) | yes | partial / no | often no | varies |
| **Directional Toxicity Shield** | **yes (signed pressure)** | **yes** | **yes** | **yes** |

On identical swap flow ([test/PriorArtComparison.t.sol](test/PriorArtComparison.t.sol), [test/DirectionalToxicityShieldMainnetComparison.t.sol](test/DirectionalToxicityShieldMainnetComparison.t.sol)):

- **Counter-flow:** Shield discounts to 2500; JDS/InfHook/VPIN stay flat at 3000 (Regis only trims to ~2559).
- **Toxic-then-quiet:** Shield decays back to 3000; JDS spikes to 6000 and InfHook to 4767 because they don't decay.
- **Vs the live Clanker static-fee hook** on a Base mainnet fork: static stays fixed across all phases while the Shield escalates → discounts → decays.

## The reactive autonomous drip

In a long-quiet market the smoothing reserve can sit stranded — the in-pool drip only fires on an organic quiet-regime swap. [Reactive Network](https://reactive.network) closes that gap with no keeper, bot, or trusted operator:

```
   Reactive (Lasna)                      Base
 ┌────────────────────┐               ┌────────────────────────┐
 │ ShieldReactive     │  cross-chain  │ callback proxy         │
 │ Controller         │ ───Callback──▶│   └─▶ ShieldReactive   │
 │ (subscribes CRON)  │  per cron tick│       Executor         │
 └────────────────────┘               │         └─▶ Shield     │
                                       │   triggerQuietDrip()   │
                                       │   donate() ──▶ LPs     │
                                       └────────────────────────┘
```

The executor never forces anything: the hook re-validates regime, cooldown, and reserve on every callback, so an ineligible pool is a safe no-op. Callback auth is two-factor — `msg.sender` must be the chain callback proxy, **and** the proxy-injected `rvm_id` must equal the registered `controllerRvmId` (locked once via `setController`).

**Live testnet proof.** On Base Sepolia ← Reactive Lasna, a cron tick delivered an authenticated `onQuietDrip` that released stranded LP reserve through `donate()` with no swap — tx [`0x7a2b6afb…ed71f`](https://sepolia.basescan.org/tx/0x7a2b6afb30e436f9da3b1bc3dde55bc5f549654443b96fc681a029313ebed71f) (block 42275501): `proxy.callback → executor.onQuietDrip → DripCallbackReceived → triggerQuietDrip → donate → DripReleased`.

Contracts: [`ShieldReactiveController`](src/reactive/ShieldReactiveController.sol) / [`ShieldReactiveControllerCronOnly`](src/reactive/ShieldReactiveControllerCronOnly.sol) (Reactive) and [`ShieldReactiveExecutor`](src/reactive/ShieldReactiveExecutor.sol) (Base).

## Public API

```solidity
// Views
function getFeePolicy(PoolId poolId) external view returns (FeePolicy memory);
function getDirectionalState(PoolId poolId) external view returns (DirectionalState memory);
function previewFee(PoolKey calldata key, SwapParams calldata params) external view returns (uint24);

// Opt-in yield smoothing (configurer-gated)
function configureSmoothing(PoolKey calldata key, SmoothingConfig calldata config) external;
function getSmoothingConfig(PoolId poolId) external view returns (SmoothingConfig memory);
function getSmoothingReserve(PoolId poolId) external view returns (SmoothingReserve memory);
```

`SmoothingConfig` is `{ bool enabled; uint32 dripBlockInterval; uint16 dripBps }`. Smoothing stays off until `configureSmoothing(enabled: true)`.

Production hook: [src/DirectionalToxicityShield.sol](src/DirectionalToxicityShield.sol). Positioning and GTM: [docs/POSITIONING.md](docs/POSITIONING.md).

## Verify

```bash
forge install
forge fmt --check
forge build
forge test          # 151 passing, 4 fork-only skipped
```

Reactive layer:

```bash
forge test --match-path 'test/reactive/*.sol'
forge test --match-path 'test/ShieldReactiveForkE2E.t.sol'
```

Against real infrastructure (Base mainnet fork — proves the Shield and the live Clanker hook share the canonical `PoolManager` `0x498581fF718922c3f8e6A244956aF099B2652b2b`, and runs the capture → escrow → drip path with value conservation `captured == dripped + remaining`):

```bash
forge test --match-contract DirectionalToxicityShieldMainnetComparisonTest --fork-url "$BASE_MAINNET_RPC_URL" -vv
forge test --match-contract DirectionalToxicityShieldSmoothingLiveDemoTest --fork-url "$BASE_MAINNET_RPC_URL" -vv
```

Captured artifacts (each row links an explorer-verifiable tx):

- Fee journey on the real PoolManager — [docs/demos/base-mainnet-fork-fee-timeline.md](docs/demos/base-mainnet-fork-fee-timeline.md)
- Live Base Sepolia fee path `3000 → 3500 → 2500 → 3000` — [docs/demos/base-sepolia-live-fee-timeline.md](docs/demos/base-sepolia-live-fee-timeline.md)
- Smoothing capture → drip on the real PoolManager — [docs/demos/base-mainnet-fork-smoothing-capture-drip.md](docs/demos/base-mainnet-fork-smoothing-capture-drip.md)
- Live Base Sepolia premium capture (6 broadcast swaps, sums to on-chain reserve to the wei) — [docs/demos/base-sepolia-live-smoothing-capture.md](docs/demos/base-sepolia-live-smoothing-capture.md)
- IL / LVR / yield-variance scoreboard — [docs/product/smoothing-proof-evidence.md](docs/product/smoothing-proof-evidence.md)

## Deploy

```bash
# Local dry run (Anvil)
forge script script/00_DeployHook.s.sol:DeployHookScript \
  --rpc-url http://127.0.0.1:8545 --private-key <ANVIL_PRIVATE_KEY> --broadcast

# Live network (use a keystore account, not a raw key)
forge script script/00_DeployHook.s.sol:DeployHookScript \
  --rpc-url <RPC_URL> --account <KEY_NAME> --sender <ADDRESS> --broadcast
```

The script mines a CREATE2 salt for the hook permission bits and deploys against the configured v4 `PoolManager`. Latest testnet runs are recorded under [deployments/](deployments/). Full testnet stage gates, the simulation/backtest harness, keystore setup, and troubleshooting live in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Security posture

- **Unaudited.** No third-party audit. Do not deploy with real capital without independent review.
- **No oracle, no admin price input.** Fees derive only from local pool state (tick movement, elapsed time, liquidity) — nothing external to manipulate.
- **Bounded by construction.** Every fee is clamped to `[minFee, maxFee]` with a per-update `maxFeeStep`; pressure is clamped to `maxPressure`. One swap can't move the fee arbitrarily.
- **Custody is opt-in.** Smoothing off (default) → no return delta, no funds held. Smoothing on → the hook holds captured premium as ERC-6909 claims before `donate()`. `configureSmoothing` is gated to the pool configurer.
- **Settlement is canonical.** Everything goes through the v4 `PoolManager` lock; the hook holds no external balances when smoothing is off.

Report security concerns privately rather than opening a public issue.

## Resources

[Uniswap v4 docs](https://docs.uniswap.org/contracts/v4/overview) · [v4-core](https://github.com/uniswap/v4-core) · [v4-periphery](https://github.com/uniswap/v4-periphery) · [Reactive Network docs](https://dev.reactive.network/)
