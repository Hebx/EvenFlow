# Directional Toxicity Shield — Static Analysis Triage

Date: 2026-06-02
Tools: Slither 0.11.5, Aderyn 0.6.8 (solc 0.8.30, evm cancun, via_ir)
Scope: first-party `src/` only — `DirectionalToxicityShield.sol` + `src/reactive/*`.
Excluded from headline report: `lib/` (v4-core/periphery, OZ, reactive-lib),
`test/`, `script/`, `src/Counter.sol` (template), `src/comparators/PriorArtComparators.sol`
(prior-art reference implementations, not the audited surface).

Reproduce: `bash audit/run.sh` (configs: `slither.config.json`, `aderyn.toml`).

## Result

No critical or high real findings on the audited surface. With scoping applied and
the two optional hardening fixes landed (see "Applied fixes" below):
- Slither: 169 contracts / 881 raw results → **50 contracts / 29 results** (deps + scripts filtered out; down from 35 pre-fix).
- Aderyn: 1 High + 9 Low (full tree) → **0 High / 7 Low** (the lone High was an
  unsafe cast inside the excluded prior-art comparators, not our hook; unused-error L-8 removed).

## Applied fixes (this pass)

1. **Removed unused `InvalidPolicyMode()` error** in `DirectionalToxicityShield.sol` (cleared Aderyn L-8).
2. **Constructor zero-address guards** (`revert ZeroAddress()`) on the production reactive wiring:
   - `ShieldReactiveExecutor`: `shield_`, `owner_`
   - `ShieldReactiveController`: `shieldHook_`, `executor_`, `cronSystem_`
   - `ShieldReactiveControllerCronOnly`: `executor_`, `cronSystem_`
   This cleared 6 of 8 Slither `missing-zero-check` findings. The 2 remaining
   (`CallbackSink`, `LegacyCronProbe`) are local probe/diagnostic contracts, not
   the production callback path — left as-is.

Verification after fixes: `forge build` green, `forge test` **157 passed / 0 failed / 4 skipped** (161 total).

| Finding | Tool | Sev | Disposition |
| --- | --- | --- | --- |
| reentrancy-no-eth in `_performDrip` | Slither | Med | ACCEPTED — runs inside PoolManager unlock; no external reentry surface (settle/donate are to canonical PM); CEI-ordered reserve update follows |
| unused-return: `poolManager.donate(...)` | Slither/Aderyn L-6 | Med/Low | ACCEPTED — `donate` returns a BalanceDelta that is irrelevant to the bounded-drip path; amounts are pre-computed and reserve decremented explicitly |
| unused-return: `poolManager.unlock(...)` | Slither | Med | ACCEPTED — `unlock` return is the callback's `""`; nothing to consume |
| unused-return: `getSlot0` tuple in `_afterSwap` | Slither | Med | ACCEPTED — only `currentTick` is needed; other slot0 fields intentionally discarded (standard v4 idiom) |
| incorrect-equality (`== 0`, `block.number ==`) | Slither | Med | ACCEPTED — exact zero/exact-block comparisons are intended (no oracle/balance equality; not the dangerous pattern) |
| reentrancy-events (3) | Slither | Low | ACCEPTED — events after PM calls; PM is trusted, state already finalized |
| timestamp comparisons (9) | Slither | Low | ACCEPTED — decay/filter windows are minute-scale; few-second miner skew cannot move a regime classification meaningfully |
| missing-zero-check on constructor addrs | Slither/Aderyn L-5 | Low | FIXED on production reactive contracts (zero-address guards added); 2 residual hits are probe/diagnostic contracts (CallbackSink, LegacyCronProbe) |
| Centralization risk (`onlyOwner` setController/registerPool) | Aderyn L-1 | Low | ACCEPTED — by design; set-once controller + owner-gated pool registration is the intended trust model |
| Unused error `InvalidPolicyMode()` | Aderyn L-8 | Low | FIXED — dead declaration removed |
| Large literal / literal-instead-of-constant (bps, 1e6) | Aderyn L-2/L-3 | Low | STYLE — `10_000`/`1_000_000` are readable bps/PPM denominators; optional named constants |
| PUSH0 / unspecific pragma | Aderyn L-4/L-7 | Low | ACCEPTED — deploy targets (Base, Ethereum) are PUSH0-capable; app pins solc 0.8.30 in foundry.toml |

## Notes on the two Mediums worth a second look

### reentrancy-no-eth in `_performDrip` (ID-11)
`settle` (burn ERC-6909 claims) → `donate` (to in-range LPs) → decrement reserve →
emit. All calls target the canonical PoolManager inside its own unlock context.
There is no untrusted external call and no ETH transfer; the reserve write is the
only state mutation and it follows the calls with pre-computed amounts. Not
exploitable. Left as-is; documented here.

### unused-return on `donate` / `getSlot0`
v4 idiom. `donate` returns the applied `BalanceDelta`; the drip path computes the
exact `drip0/drip1` it intends to release and decrements the reserve by those
same values, so the return delta carries no additional info to check. `getSlot0`
returns a 4-tuple where only `currentTick` is used.

## Suggested follow-ups (optional, not blocking)
1. ~~Remove unused `InvalidPolicyMode()` error~~ — DONE.
2. ~~Add `require(x != address(0))` in reactive constructors~~ — DONE (production contracts).
No remaining blocking items; the core fee + smoothing + reactive paths are clean.

## Verification
- `forge build`: green (solc 0.8.30, via_ir).
- `forge test`: 157 passed / 0 failed / 4 skipped (161 total, 23 suites).
- Reports: `audit/slither-report.md`, `audit/aderyn-report.md`.
