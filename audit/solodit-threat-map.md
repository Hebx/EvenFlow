# Solodit Prior-Art → Threat Map (Directional Toxicity Shield)

> Source: Cyfrin Solodit findings API, queried 2026-06-01. These are *real shipped
> bugs* from audits of comparable hooks. Each is mapped to our actual code and given
> a residual-risk call. This is local-only research, not a published audit.
>
> Our drip releases value via `poolManager.donate()` to in-range LPs
> (`DirectionalToxicityShield.sol:568`, in `_performDrip`). That single fact is what
> makes the donation/JIT finding-class directly applicable to us.

## TL;DR severity for us
| # | Finding (prior art) | Class | Applies to | Residual risk |
|---|---------------------|-------|------------|---------------|
| 1 | Flayer H-20 — donation sandwichable in one tx (Sherlock) | JIT/donate MEV | `_performDrip` donate | **MEDIUM**, partly mitigated |
| 2 | OZ — Liquidity Penalty circumvented via 2 accounts | JIT/donate MEV | `_performDrip` donate | **MEDIUM**, partly mitigated |
| 3 | OZ — JIT Liquidity Penalty can be bypassed / AntiSandwich JIT | JIT/donate MEV | `_performDrip` donate | **MEDIUM** |
| 4 | Licredity (Cyfrin, Q5) — self-triggered afterSwap LP fee farming | reflexive fee mining | capture→drip in afterSwap | **LOW–MEDIUM**, verify |
| 5 | Bunni (Cyfrin) — surge fee can exceed 100% → reverts | fee bound | fee override path | **LOW**, we bound it |
| 6 | Sorella Angstrom (Cyfrin) — dynamic fee missing afterSwapReturnDelta perm → revert | hook perms | permissions/flags | **LOW**, verify flags |
| 7 | OZ — DynamicAfterFee avoidable by specifying output amount | fee evasion | capture in afterSwap | **LOW–MEDIUM**, verify |
| 8 | The Compact (Spearbit) — bypass reentrancy lock, double-spend | transient lock | tstore/tload flags | **LOW**, verify clearing |

---

## 1–3. Donation / JIT MEV (the headline risk for our drip)
**Prior art:**
- **Flayer H-20** (Sherlock, HIGH): donation fees are sandwichable in one tx. Root
  cause = *allowing more than a max donation per transaction/block*. Even with a
  per-tx cap, an attacker loops donations, so the fix is a **per-block** donation
  limit. Quotes Uniswap's own warning: `donate` can be front-run by JIT liquidity.
- **OZ LiquidityPenaltyHook — circumvented via secondary accounts** (HIGH): because
  `donate` rewards whoever is in-range *at donate time*, two coordinated accounts can
  redirect donated fees to an opportunistically-positioned account. OZ's suggested
  mitigation: detect abrupt large tick changes in a single block; withhold/delay/
  pro-rate donations over time.
- **OZ JIT Penalty bypass / AntiSandwich JIT** (HIGH): same family — JIT added/removed
  in the same block still captures value.

**Our code:** `_performDrip` calls `poolManager.donate(key, drip0, drip1, "")` to
in-range LPs at `slot0.tick`. An attacker who can predict a drip can JIT-add narrow
in-range liquidity just before it and capture a share they didn't earn.

**What we already do right (partial mitigation):**
- **Per-pool cooldown:** `_dripReady` enforces `block.number - lastDripBlock >=
  dripBlockInterval`. This is effectively the per-block donation limit Flayer asks
  for — we can't be looped within a block, and not every block.
- **Bounded slice:** drip is only `dripBps/10_000` of reserve per release, so a single
  captured drip is a small fraction, not the whole escrow.
- **Quiet-regime gate:** drip only fires when the pool is quiet (low pressure), which
  is exactly when JIT positioning is cheapest *but* also when captured value per drip
  is smallest.

**Residual risk: MEDIUM.** The cooldown + bounded fraction blunt the Flayer loop and
cap per-event loss, but they do **not** stop the OZ two-account / JIT-in-range
redirection: a patient attacker can still JIT narrow liquidity in the block a drip
lands and skim that drip's bounded slice. The economic question is whether the skim
exceeds gas + the LP's own in-range risk for one block. With small `dripBps` it's
often not profitable, but it's not structurally prevented.

**Recommended follow-ups (test, don't just assert):**
- Write a Foundry PoC: JIT-add narrow in-range liquidity one block before a drip,
  remove after, measure captured donation vs honest in-range LPs. Quantify break-even.
- Consider tracking liquidity-age / withholding drip if in-range liquidity changed
  sharply in the last block (OZ's suggestion), or pro-rating drip across several
  blocks so no single JIT block captures it all.
- Confirm `dripBps` default is low enough that JIT skim < gas at realistic reserves.

## 4. Reflexive fee mining (Licredity, Cyfrin, quality 5)
**Prior art:** Licredity's `_afterSwap` auto back-runs a swap when price crosses a
threshold, paying swap fees to LPs. A dominant LP loops: push price, earn fees on the
push, trigger the hook's back-run, earn fees again, redeem ~1:1 — extracting value
repeatedly with low price risk.

**Our code:** we don't back-run swaps, but we do **capture premium in `beforeSwap` and
drip in `afterSwap`**, and drip rewards in-range LPs. The analogous question: can a
dominant LP *manufacture* toxic flow (to fill the reserve) and then be the in-range
recipient of the drip, recovering their own toxic-fee contribution? Capture and drip
are separated by the cooldown and the quiet-regime gate, which breaks the same-tx
loop Licredity had — but a multi-block version deserves a PoC.

**Residual risk: LOW–MEDIUM — verify with a multi-block self-dealing PoC.**

## 5. Fee exceeding 100% → reverts (Bunni, Cyfrin)
**Prior art:** surge fee math overflowed 100%, causing reverts / overcharge.
**Our code:** fee is bounded by `policy.maxFee` and `_validatePolicy`; presets cap at
30_000 (3%). `_policyModePreset` modes are all well under 100%.
**Residual risk: LOW.** Confirm no path sums base+directional premium past the cap
before clamping; add an invariant `appliedFee <= maxFee`.

## 6. Missing afterSwapReturnDelta permission → revert (Sorella Angstrom, Cyfrin)
**Prior art:** dynamic fee enabled but hook permission flags didn't encode
`afterSwapReturnDelta`, so swaps reverted with `CurrencyNotSettled()`.
**Our code:** we `take` in beforeSwap (line 256) and `settle`+`donate` in the drip —
both move deltas. Verify `getHookPermissions()` encodes every return-delta flag the
code actually uses (beforeSwap + afterSwap return deltas as applicable).
**Residual risk: LOW — mechanical, verify the flags vs the deltas we move.**

## 7. DynamicAfterFee avoidable by specifying output (OpenZeppelin)
**Prior art:** users dodged an after-swap fee by specifying the desired output amount
(exact-output), and the target delta reset each swap.
**Our code:** premium capture happens on aligned swaps in beforeSwap; verify capture
is symmetric for exactInput vs exactOutput and zeroForOne vs oneForZero, so a trader
can't pick a swap direction/kind that escapes capture.
**Residual risk: LOW–MEDIUM — verify capture covers all four swap shapes.**

## 8. Reentrancy-lock bypass / double-spend (The Compact, Spearbit)
**Prior art:** transient-storage reentrancy lock could be bypassed to double-spend.
**Our code:** we use EIP-1153 transient slots (`PREMIUM_CAPTURE_SLOT`,
`PRE_SWAP_QUIET_OFFSET`, apply-capture flag). Verify every transient flag is written
and read within the same unlock and **cleared** so a second swap in the same tx can't
read a stale capture flag.
**Residual risk: LOW — verify transient lifecycle with a two-swaps-one-tx test.**

---

## Reactive path — checked, looks sound
`triggerQuietDrip` (1) gates on `msg.sender == reactiveExecutors[poolId]`, (2)
**recomputes** quiet regime + `_dripReady` from the hook's own decayed state, treating
the callback as a *trigger only*, and (3) routes the actual release through
`unlockCallback` guarded by `onlyPoolManager`. Rejected actions emit and no-op without
touching the fee path. `applyPolicyMode` only selects among 3 bounded presets and
re-runs `_validatePolicy` — no arbitrary fee injection. This matches the cross-chain
guidance in the defi-protocol-audit skill. The donate inside `_performDrip` inherits
the same JIT exposure as #1–3 (same code path), so it's covered there.

## Next actions
1. Build the JIT-drip PoC (#1–3) — highest-value, quantifies the headline risk.
2. Multi-block self-dealing PoC for reflexive mining (#4).
3. Mechanical verifications (#5–8): fee-cap invariant, hook-permission flags,
   capture symmetry across swap shapes, transient-flag clearing.
4. Then run the approved static set (Slither + Aderyn) and Halmos on the fee + drip
   functions to catch anything the manual pass missed.
