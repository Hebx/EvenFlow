# Smoothing IL/Yield Proof Layer — Evidence

**Status:** captured artifact for the proof layer. All numbers are reproducible from this repo via `forge test` / `forge script`.
**Sources:**
- Mechanism: `src/DirectionalToxicityShield.sol`
- Reproduce the scoreboard: `script/SmoothingProofReport.s.sol`

---

## 1. What this document is

The smoothing mechanism is built and live (`bcc5469` reactive integration,
`cd8c68d` Phase-3 variance metric). It claims to deliver impermanent-loss and
yield value for LPs. This doc is the receipt: the proof that the claim holds,
expressed as a scoreboard the reviewer can reproduce by running `forge test`.

The proof layer is split into five phases:

| Phase | What it proves                                        | Commit      |
| :---- | :----------------------------------------------------- | :---------- |
| 1     | IL/LVR pure helpers anchored to textbook values        | `64f36db`   |
| 2     | Capture/drip math = on-chain math, to the wei          | `18cb482`   |
| 3     | Unified scoreboard with conservation as a hard gate    | `2a2d757`   |
| 4     | Head-to-head with `LiquidityPenaltyHook`               | `0612cd2`   |
| 5     | This evidence doc                                      | (this commit) |

Each phase is a separate test file under `test/utils/`; the report itself is
`script/SmoothingProofReport.s.sol`.

---

## 2. Reading the scoreboard

The unified scoreboard runs three canonical scenarios on the SAME tick path
the variance metric uses (single source of truth — exposed via
`stepsBurstThenQuiet/_sustainedToxic/_choppy()` on `YieldSmoothingMetric`).

For each scenario it reports:

- **Variance / conservation:** raw vs. smoothed total yield, escrow remaining,
  total captured / dripped, raw vs. smoothed `sigma`, efficacy in bps.
- **Coefficient of variation:** `sigma / mean` for raw and smoothed streams,
  in bps. CoV normalises out the mean so the comparison survives across
  scenarios with different absolute fee sizes.
- **IL / LVR on the shared path:** final price, closed-form IL fraction at
  endpoint (in WAD), IL value in token1 units, and cumulative discrete
  path-exact LVR.

All numbers below are reproducible by

```sh
forge script script/SmoothingProofReport.s.sol:SmoothingProofReport
```

Position size for the IL/LVR side: 1,000,000 token0 + 1,000,000 token1 at
P0 = 1.0 (numeraire token1). LVR is the *coarse* discrete sum: it is a
documented lower bound on the continuous rebalancing cost (finer steps ⇒
larger LVR; see model doc §4).

---

## 3. The numbers

### 3.1 Burst then quiet (canonical smoothing case)

| field                | value (raw units) |
| :------------------- | ----------------: |
| raw total yield      | 4.5700e22         |
| smoothed paid yield  | 4.5678e22         |
| escrow still owed    | 2.2173e19         |
| total captured       | 7.0000e20         |
| total dripped        | 6.7783e20         |
| raw sigma            | 1.3098e20         |
| smoothed sigma       | 5.1186e19         |
| efficacy             | **+6093 bps**     |
| CoV raw              | **429 bps**       |
| CoV smoothed         | **168 bps**       |
| final price          | 1.00602           |
| IL fraction          | -4.50e-6          |
| IL value (token1)    | -9.03             |
| cumulative LVR       |  3.01             |

Reading: a short toxic burst followed by quiet flow is the case the
mechanism was designed for. Smoothing cuts the per-step yield variance by
**~61%** (efficacy 6093 bps), which translates to CoV dropping from 429 to
168 bps — a **2.5× tighter** yield distribution at essentially conserved
total yield (`paid + escrow == raw`, exact). IL and LVR are both modest at
this displacement (<1% price move).

### 3.2 Sustained toxic trend (capture-dominant)

| field                | value (raw units) |
| :------------------- | ----------------: |
| raw total yield      | 5.1200e22         |
| smoothed paid yield  | 5.0880e22         |
| escrow still owed    | 3.2036e20         |
| total captured       | 3.2000e21         |
| total dripped        | 2.8796e21         |
| raw sigma            | 2.3717e20         |
| smoothed sigma       | 2.4108e20         |
| efficacy             | **-164 bps**      |
| CoV raw              | 741 bps           |
| CoV smoothed         | 758 bps           |
| final price          | 1.01613           |
| IL fraction          | -3.20e-5          |
| IL value (token1)    | -64.51            |
| cumulative LVR       |  8.04             |

Reading: when toxicity is sustained (not bursty), the surplus fee is *also*
sustained and the per-step stream is already roughly flat. Smoothing has
nothing to flatten — efficacy goes mildly negative because the drip lag adds
its own micro-variance. Conservation still holds exactly. **This is honest
disclosure: smoothing's value is regime-dependent.** In trending markets the
hook still does its directional fee job (see live mainnet/Sepolia demos);
the smoothing layer simply contributes no extra variance reduction here.

### 3.3 Choppy alternating flow (low-capture stress)

| field                | value (raw units) |
| :------------------- | ----------------: |
| raw total yield      | 4.7500e22         |
| smoothed paid yield  | 4.4400e22         |
| escrow still owed    | 3.1000e21         |
| total captured       | 3.1000e21         |
| total dripped        | **0**             |
| raw sigma            | 4.4260e20         |
| smoothed sigma       | 2.3585e20         |
| efficacy             | **+4672 bps**     |
| CoV raw              | 1490 bps          |
| CoV smoothed         | 849 bps           |
| final price          | 1.00000           |
| IL fraction          | 0                 |
| IL value (token1)    | 0                 |
| cumulative LVR       | **16.01**         |

Reading: this is the most informative scenario. Three observations:

1. **IL = 0 at endpoint, but LVR is the largest of the three.** Choppy flow
   round-trips price to P0 so closed-form IL is zero, yet the arber profits
   on every swing. This is the textbook IL-vs-LVR distinction made
   numerically concrete on a path the hook actually runs.
2. **Efficacy is strong (4672 bps) — smoothing flattens the sigma well.**
3. **But total dripped = 0.** The reserve fills on every toxic edge and
   never empties because the alternating flow always re-triggers capture
   before the on-chain drip cadence fires. **All 3.1e21 of premium is
   stranded in escrow.** This is exactly the failure mode the Reactive
   CRON drip exists to solve: an off-chain heartbeat that pulses
   `kickReserveDrip` regardless of on-flow regime.

This scenario alone justifies the reactive integration shipped in
`bcc5469`.

---

## 4. Conservation is hard-gated

`test_conservation_holdsInEveryScenario` asserts two equalities on every
scenario, with no tolerance:

```
smoothedPaidTotal + finalReserve == rawTotal      (total yield is conserved)
totalCaptured     - totalDripped  == finalReserve (escrow accounts for itself)
```

The smoothing layer cannot create or destroy yield. It can only re-time it.
Any future change that breaks this gate fails CI.

---

## 5. Capture/drip math = on-chain math (Phase 2 parity)

`SmoothingCaptureMath` is a pure library that mirrors the contract's
arithmetic:

- `capturePremiumBps = (fee - baseFee) * 1e4 / fee` (0 when fee ≤ baseFee)
- `capturedAmount   = absUnspecified * premiumBps / 1e4`
- `dripAmount       = reserve * dripBps / 1e4`

The parity test drives a real capturing swap through the deployed hook,
reads the applied fee from `FeeOverrideApplied` and the gross unspecified
amount from the v4 `Swap` event, and asserts the pure library reproduces
the observed on-chain reserve growth **exactly to the wei**. Drip parity
primes a reserve, goes quiet, kicks the on-chain drip, and asserts the
donated amount matches `reserve * dripBps / 1e4` to the wei.

This means the IL/LVR scoreboard above is computed against a model whose
capture/drip arithmetic is the same arithmetic the deployed contract runs.

---

## 6. Comparable: `LiquidityPenaltyHook`

The OpenZeppelin Uniswap-Hooks repo ships exactly one hook that uses the
`donate()`-to-in-range primitive: `LiquidityPenaltyHook` (JIT defense).
Phase 4 documents the relationship as **complementary**, not competitive:

| trait                   | Shield (this hook)             | LiquidityPenaltyHook        |
| :---------------------- | :----------------------------- | :-------------------------- |
| trigger surface         | `beforeSwap` / `afterSwap`     | `afterAddLiquidity` / `afterRemoveLiquidity` |
| threat model            | directional toxic flow         | JIT add+remove within N blocks |
| primitive               | dynamic LP fee + donate drip   | feeDelta penalty + donate   |
| permission flag overlap | none                           | none                        |
| could coexist on a pool | yes                            | yes                         |

The two hooks defend disjoint surfaces with the same redistribution
primitive. `test_hookPermissions_areDisjoint_canCoexistByDesign` pins this
at the bytecode level.

The LPH redistribution math itself is upstream-tested in the vendored
library; we don't re-test it here.

**Real-infra:** OZ's `LiquidityPenaltyHook` has no canonical live deployment
(it's a library, deployed per-pool), so the real-infra bar is running the
comparison against the **real canonical Base mainnet `PoolManager`** that
production hooks use. The head-to-head extends `BaseTest`, which resolves that
PoolManager via `AddressConstants` on a fork — so all three Phase 4 tests pass
unchanged against real Base mainnet infra (`--fork-url $BASE_MAINNET_RPC_URL`),
not just a local PoolManager.

---

## 7. Honest caveats

- **Efficacy is regime-dependent.** Burst-then-quiet and choppy: strong
  positive efficacy. Sustained trending: ~neutral. The hook's directional
  fee job is what defends LPs in trending regimes; smoothing is a
  *complementary* variance reducer.
- **Choppy strands reserves.** The on-chain drip cadence cannot empty a
  reserve that keeps re-filling. The Reactive CRON drip is the fix and is
  already deployed; reserve emptiness in the choppy scenario is the
  motivation, not a bug.
- **Discrete LVR is a lower bound.** Coarse N-step LVR ≈ endpoint IL / N
  for monotone paths. The real continuous rebalancing cost is larger; we
  use the coarse number because it matches the discrete tick path and is
  what `forge` can compute deterministically.
- **All scoreboard numbers are model output.** Capture/drip math is
  contract-parity (Phase 2). Variance + conservation are direct measurement
  on the simulated stream. IL/LVR are textbook closed-form / discrete path
  formulas anchored to known values (Phase 1).

---

## 8. Reproduce locally

```sh
# Pure helpers (Phase 1)
forge test --match-path test/utils/SmoothingILMath.t.sol -vv

# Capture/drip parity (Phase 2)
forge test --match-path test/utils/SmoothingCaptureMath.t.sol -vv

# Unified scoreboard + conservation gate (Phase 3)
forge test --match-path test/utils/SmoothingProofReport.t.sol -vv

# Head-to-head with LiquidityPenaltyHook (Phase 4)
forge test --match-path test/utils/LiquidityPenaltyHeadToHead.t.sol -vv

# Same head-to-head against the REAL Base mainnet PoolManager (real-infra)
forge test --match-contract LiquidityPenaltyHeadToHeadTest \
  --fork-url "$BASE_MAINNET_RPC_URL" -vv

# Print the scoreboard
forge script script/SmoothingProofReport.s.sol:SmoothingProofReport
```

Full suite: 157 passed / 0 failed / 4 skipped (RPC-gated fork tests).

---

## 9. On-chain counterpart (live-infra proof)

Everything above is a **model**: the scoreboard measures variance/IL/LVR over
simulated streams, with the Phase 2 parity test bounding drift from the deployed
math. The remaining question — does the capture→escrow→drip plumbing actually
*execute* on real v4 infrastructure — is answered on-chain by
[`test/DirectionalToxicityShieldSmoothingLiveDemo.t.sol`](../../test/DirectionalToxicityShieldSmoothingLiveDemo.t.sol),
captured in [`docs/demos/base-mainnet-fork-smoothing-capture-drip.md`](../demos/base-mainnet-fork-smoothing-capture-drip.md).

It drives organic toxic flow through the **real canonical Base mainnet
`PoolManager`** (`0x498581fF718922c3f8e6A244956aF099B2652b2b`, chainid 8453) on a
fork — no harness `setPressure`/`setFeePolicy` cheats — then asserts:

- premium is escrowed as ERC-6909 claims during the toxic run (reserve climbs to
  `1.0349e18`),
- a quiet-regime swap releases exactly `dripBps` (20% → `0.2070e18`) to in-range
  LPs via `donate`,
- value is conserved: `captured == dripped + remaining` (hard-gated).

```sh
forge test --match-contract DirectionalToxicityShieldSmoothingLiveDemoTest \
  --fork-url "$BASE_MAINNET_RPC_URL" -vv
```

This proves the on-chain mechanism the model assumes. A realized-LP-yield
claim from live capital still requires a live pool observed over organic flow.
