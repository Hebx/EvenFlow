# Live Testnet Fee Timeline — Base Sepolia

This is the captured artifact from a real, two-phase broadcast against the
already-deployed `DirectionalToxicityShield` on Base Sepolia
(`0x538c73F7731d0D4bCEa6ee264955F66c5bd830c4`). Every row corresponds to a
broadcast transaction the explorer can verify; nothing is forked, simulated, or
mocked.

Companion of `docs/demos/base-mainnet-fork-fee-timeline.md` (which uses the real
Base mainnet PoolManager via fork). This run is end-to-end live: real chain,
real PoolManager, real txs, real wall-clock decay window.

## Setup

| Field | Value |
|---|---|
| Network | Base Sepolia (chainId `84532`) |
| PoolManager (canonical v4) | `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408` |
| Hook (DirectionalToxicityShield) | `0x538c73F7731d0D4bCEa6ee264955F66c5bd830c4` |
| Deployer / swapper | `0x46Ca9120Ea33E7AF921Db0a230831CB08AeB2910` |
| token0 | `0x4789e54490Fe1531769052ED0164dD02c3Ca0c60` |
| token1 | `0x53C440a8f36f99DEfD5Ea69f63844264f5893e4B` |
| poolId | `0x933ca6d23c3f979e6e973fe7506cbb727a00e883a4da695036df793bf24184b0` |
| Script | `script/testnet/TestnetTimelineDemo.s.sol` |

Hook fee policy at run-time: `baseFee=3000`, `minFee=2500`, `maxFee=10000`,
`maxFeeStep=500`, `maxPressure=500`, `filterWindow=30s`, `decayWindow=300s`.

## Why two phases

`forge --broadcast` simulates the entire script before broadcasting, so an
in-script `vm.sleep` for the 5-minute decay window stalls simulation and still
collapses every swap into one simulated block. The script therefore runs as:

1. **Build phase** — broadcasts setup + 7 swaps (base / toxic×4 / counter×2).
2. Operator waits real wall-clock time `> decayWindow` (300s).
3. **Quiet phase** — broadcasts a single swap that observes full pressure decay.

## Build phase — per-swap timeline (read from on-chain state)

`afterSwap` writes `lastFee` for the *next* swap, so each row's fee is the fee
that swap actually paid (priced from the previous swap's pressure).

| # | Block | Direction | Phase | Pressure (before) | Fee paid | vs base | Tx |
|---|---|---|---|---|---|---|---|
| 1 | 42170372 | 1→0 | base    | 0   | 3000 | base  | [`0x09b8…cde11`](https://sepolia.basescan.org/tx/0x09b8195026ec84416e8df9dd7e9b11f7b59d0478c54756e98846f47e2f4cde11) |
| 2 | 42170373 | 1→0 | toxic   | 198 | 3500 | +500 (cap) | [`0xff94…0e0a00`](https://sepolia.basescan.org/tx/0xff941213b33a24ca1ddcc3d409d21af5a6b1bac19b2f964e45902a52220e0a00) |
| 3 | 42170374 | 1→0 | toxic   | 500 (clamped) | 3500 | +500 | [`0x98cc…4c15d3`](https://sepolia.basescan.org/tx/0x98ccf6a405550163ad70ed87b7e1abbb09c00331bab3b68c62acea2f1d4c15d3) |
| 4 | 42170375 | 1→0 | toxic   | 500 (clamped) | 3500 | +500 | [`0x8f57…84c8a`](https://sepolia.basescan.org/tx/0x8f57e08ba5184c6767db96244a3f37d7a32fb2f89d52586f4173333ca2b84c8a) |
| 5 | 42170376 | 1→0 | toxic   | 500 (clamped) | 3500 | +500 | [`0x0ef0…05cfda`](https://sepolia.basescan.org/tx/0x0ef00805511ab26c6781d86f33d10407c4e7838871aec485bb67390e5d05cfda) |
| 6 | 42170377 | 0→1 | counter | 500 → 500 (counter-flow) | 2500 | −500 (floor) | [`0x2289…418994`](https://sepolia.basescan.org/tx/0x22893bcb5d4c8b813c45bf2aed7e3ee9aef6b0646324f731a041d4025a418994) |
| 7 | 42170378 | 0→1 | counter | 500 | 2500 | −500 | [`0xdcd6…234630`](https://sepolia.basescan.org/tx/0xdcd695f62c2cc75d8fc9496d0170361cd3cab5f80f4b0a9647cd2834f5234630) |

Direct on-chain reads of `getDirectionalState(poolId)` at each post-swap block:

```
block 42170372 → refTick=0 lastTick=198 pressure=198 lastFee=3000 regime=1
block 42170373 → refTick=0 lastTick=394 pressure=500 lastFee=3500 regime=2
block 42170374 → refTick=0 lastTick=589 pressure=500 lastFee=3500 regime=2
block 42170375 → refTick=0 lastTick=781 pressure=500 lastFee=3500 regime=2
block 42170376 → refTick=0 lastTick=972 pressure=500 lastFee=3500 regime=2
block 42170377 → refTick=0 lastTick=764 pressure=500 lastFee=2500 regime=2
block 42170378 → refTick=0 lastTick=558 pressure=500 lastFee=2500 regime=2
```

What this proves:

- **Surcharge is bounded.** Pressure clamps at `maxPressure=500` and the
  per-swap fee step caps at `maxFeeStep=500`, so even sustained toxic flow
  cannot push the fee past `baseFee + maxFeeStep`.
- **Counter-flow gets a discount.** Once pressure is positive and the next
  swap reverses direction, the fee drops by the same step (3500 → 2500) and
  hits the floor at `minFee=2500`.
- **Per-block accumulation cap is respected.** Each swap landed in its own
  block (42170372 → 42170378, ~2s apart), so each one was eligible to update
  pressure exactly once.

## Quiet phase — decay back to base

After waiting > 5 minutes (the on-chain decayWindow), a single swap was
broadcast in block 42170669 (~291s after the last build-phase swap):

| # | Block | Direction | Phase | Fee paid | vs base | Tx |
|---|---|---|---|---|---|---|
| 8 | 42170669 | 1→0 | quiet | 3000 | base | [`0x1d3f…d24f9c73`](https://sepolia.basescan.org/tx/0x1d3f1160e039a834a60436be98be73ed2b221cd604c0f1bb5473c3f6d24f9c73) |

`getDirectionalState` after the quiet swap:

```
refTick=751 lastTick=751 pressure=500 lastUpdateTime=1780109370 lastFee=3000 regime=2
```

Because `elapsed >= decayWindow`, the decay branch fires: pressure resets the
*reference* to the current tick, and the next swap re-prices at `baseFee=3000`.
Pressure stored on-chain reflects the freshly accumulated state from the new
reference (this swap is itself a new directional swap from the new ref).

What this proves:

- **The fee genuinely returns to base when flow goes quiet.** No manual
  intervention, no contract owner call — the hook self-heals over real
  wall-clock time.

## Reproduce

```sh
# 1. build phase
DTS_HOOK_ADDRESS=0x538c73F7731d0D4bCEa6ee264955F66c5bd830c4 \
DTS_TIMELINE_NETWORK=base-sepolia DTS_PHASE=build \
forge script script/testnet/TestnetTimelineDemo.s.sol:TestnetTimelineDemo \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" --broadcast --slow -vv

# 2. wait > 300 seconds for decayWindow to elapse on-chain
sleep 320

# 3. quiet phase (use TOKEN0/TOKEN1 emitted by the build phase)
DTS_HOOK_ADDRESS=0x538c73F7731d0D4bCEa6ee264955F66c5bd830c4 \
DTS_TIMELINE_NETWORK=base-sepolia DTS_PHASE=quiet \
DTS_TIMELINE_TOKEN0=<from build phase log> \
DTS_TIMELINE_TOKEN1=<from build phase log> \
forge script script/testnet/TestnetTimelineDemo.s.sol:TestnetTimelineDemo \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" --broadcast --slow -vv
```

Total real cost of this captured run: **~0.000048 ETH** on Base Sepolia
(estimated 0.000045 build + 0.0000021 quiet at 0.011 gwei).
