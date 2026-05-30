# Unichain Sepolia Stage 3 Run - 2026-05-30

Network: Unichain Sepolia
Chain ID: `1301`
Explorer: `https://sepolia.uniscan.xyz`
Deployer: `0x46Ca9120Ea33E7AF921Db0a230831CB08AeB2910`

> Redeploy after the hardening polish (policy invariant validation + per-block
> pressure accumulation cap). Supersedes `unichain-sepolia-stage3-2026-05-25.md`.
> Hook bytecode now includes the `lastPressureBlock` field on `DirectionalState`
> and the named `_validatePolicy` errors.

## Canonical v4 Contracts

- `PoolManager`: `0x00B036B58a818B1BC34d502D3fE730Db729e62AC`
- `PositionManager`: `0xf969Aee60879C54bAAed9F3eD26147Db216Fd664`
- `Hookmate V4 SwapRouter`: `0x9cD2b0a732dd5e023a5539921e0FD1c30E198Dba`

## Deployed Scenario Contracts

- `DirectionalToxicityShield`: `0x69a0299423399f51C387fCf3ADF67485a67aB0C0`
- `token0`: `0x2c415A0af12BC364F96b6a3b657fCfaD2a1438C3`
- `token1`: `0x8737a7f137dD4cAA1686f6a18e41902967B8647c`
- `PoolId`: `0x57e1c5eb39250f8fcaa4537f3d5fb08adbc357ce22cfefe016d43b25e56d58e6`

## Result

Two same-direction swaps were executed against a dynamic-fee hooked pool. Each
swap landed in its own block, so directional pressure accumulated to the cap.

- First applied fee: `3000`
- Second applied fee: `3500`
- Final pressure: `500`
- Final tick: `394`
- Final regime: `2`
- `lastPressureBlock`: `53248409` (new field, confirms upgraded struct is live)

Readback command (note the extra trailing `uint40` for `lastPressureBlock`):

```bash
cast call --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL" \
  0x69a0299423399f51C387fCf3ADF67485a67aB0C0 \
  "getDirectionalState(bytes32)(int24,int24,int56,uint40,uint24,uint8,uint40)" \
  0x57e1c5eb39250f8fcaa4537f3d5fb08adbc357ce22cfefe016d43b25e56d58e6
```

Readback output:

```text
0
394
500
1780100837
3500
2
53248409
```

## Notes

- All 16 scenario transactions confirmed (status 0x1) across blocks
  53248381-53248409.
- The first broadcast attempt stalled on the Unichain Sepolia sequencer
  (txs dropped/late-mined). Re-running with `--slow` (sequential send +
  per-tx confirmation) and reusing the already-deployed hook via
  `DTS_HOOK_ADDRESS` produced a clean run.
- Forge simulation reports pressure=198/regime=1 because it executes both
  swaps in one simulated block; the per-block cap intentionally limits
  same-block accrual. On-chain each swap is its own block, so pressure
  reaches 500/regime=2.

Broadcast artifact:

```text
broadcast/UnichainSepoliaScenario.s.sol/1301/run-latest.json
```
