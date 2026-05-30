# Base Sepolia Stage 3 Run - 2026-05-30

Network: Base Sepolia
Chain ID: `84532`
Explorer: `https://sepolia.basescan.org`
Deployer: `0x46Ca9120Ea33E7AF921Db0a230831CB08AeB2910`

> Redeploy after the hardening polish (policy invariant validation + per-block
> pressure accumulation cap). Supersedes `base-sepolia-stage3-2026-05-25.md`.
> Hook bytecode now includes the `lastPressureBlock` field on `DirectionalState`
> and the named `_validatePolicy` errors. Matches the Unichain Sepolia redeploy
> in `unichain-sepolia-stage3-2026-05-30.md`.

## Canonical v4 Contracts

Resolved via `AddressConstants` for chain `84532`.

## Deployed Scenario Contracts

- `DirectionalToxicityShield`: `0x8fE7A4fb990753dB1eB39eBAf4399eaCE25BB0c0`
- `token0`: `0x4c8CcCdC3008aAb27A912de2e3dD5F5a57E54967`
- `token1`: `0x67bD4f5E39003a42A2F6F7fbc1c4CA2BDF416BDA`
- `PoolId`: `0xa5189339277920f6c7b75958649f0e869a133c307f145f7fb6c834789d6a1ca5`

## Result

Two same-direction swaps were executed against a dynamic-fee hooked pool. Each
swap landed in its own block, so directional pressure accumulated to the cap.

- First applied fee: `3000`
- Second applied fee: `3500`
- Final pressure: `500`
- Final tick: `394`
- Final regime: `2`
- `lastPressureBlock`: `42166376` (new field, confirms upgraded struct is live)

Readback command (note the extra trailing `uint40` for `lastPressureBlock`):

```bash
cast call --rpc-url "$BASE_SEPOLIA_RPC_URL" \
  0x8fE7A4fb990753dB1eB39eBAf4399eaCE25BB0c0 \
  "getDirectionalState(bytes32)(int24,int24,int56,uint40,uint24,uint8,uint40)" \
  0xa5189339277920f6c7b75958649f0e869a133c307f145f7fb6c834789d6a1ca5
```

Readback output:

```text
0
394
500
1780101040
3500
2
42166376
```

## Notes

- All 17 scenario transactions confirmed (status 0x1) across blocks
  42166360-42166376.
- Broadcast with `--slow` (sequential send + per-tx confirmation), the same
  approach that produced a clean Unichain Sepolia run.
- Forge simulation reports pressure=198/regime=1 because it executes both swaps
  in one simulated block; the per-block cap intentionally limits same-block
  accrual. On-chain each swap is its own block, so pressure reaches
  500/regime=2.

Broadcast artifact:

```text
broadcast/BaseSepoliaScenario.s.sol/84532/run-latest.json
```
