# Live Testnet Smoothing Capture — Base Sepolia

Captured artifact from a real broadcast against the already-deployed
smoothing-enabled `DirectionalToxicityShield` on Base Sepolia
(`0xf9664050d816d0cAD201B318A30E9D4C4eA270c4`). Every row corresponds to a
broadcast transaction the explorer can verify; nothing is forked, simulated, or
mocked.

This is the **live-testnet counterpart** to the fork capture→drip proof
([`base-mainnet-fork-smoothing-capture-drip.md`](base-mainnet-fork-smoothing-capture-drip.md))
and the off-chain efficacy scoreboard
([`../product/smoothing-proof-evidence.md`](../product/smoothing-proof-evidence.md)).
It proves the **capture + escrow** half of the smoothing layer on a real chain.
The **drip release** half on testnet is staged separately (see "Drip status"
below).

## Setup

| Field | Value |
|---|---|
| Network | Base Sepolia (chainId `84532`) |
| PoolManager (canonical v4) | `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408` |
| Hook (DirectionalToxicityShield, smoothing build) | `0xf9664050d816d0cAD201B318A30E9D4C4eA270c4` |
| SwapRouter (Hookmate v4) | `0x71cD4Ea054F9Cb3D3BF6251A00673303411A7DD9` |
| Deployer / swapper | `0x46Ca9120Ea33E7AF921Db0a230831CB08AeB2910` |
| token0 | `0x14eCdfD4a7dbf9E79f6085d13D96F421456FB2a4` |
| token1 | `0x59A6543ee51f0E6d3D9CDe7D30112b315b76beD3` |
| poolId | `0xcaa1b7d8d6f50c015e62d713f2f55154cd6dd6dad4bf3aeb966cdf8eec34577b` |
| Script | `script/reactive/BuildReserveBaseSepolia.s.sol` |

Smoothing config read on-chain (`getSmoothingConfig(poolId)`): `enabled=true`,
`dripInterval=5` blocks, `dripBps=2000` (20%).

## Capture timeline — per-swap (read from on-chain receipts)

Six same-direction (`zeroForOne=true`, `amountIn=5e18`) swaps, each in its own
block, accumulate directional pressure so the fee climbs above `baseFee`; the
premium fraction is skimmed from the unspecified currency (token1) and escrowed
as ERC-6909 claims. `PremiumCaptured(poolId, amount0, amount1)` is emitted per
capturing swap.

| # | Block | PremiumCaptured | amount1 captured (wei) | Tx |
|---|---|---|---|---|
| 1 | 42193739 | no (reference tick) | 0 | [`0xaf29…72b1`](https://sepolia.basescan.org/tx/0xaf29861030a0c24751664b88b3c1286ce69a0b497bd53b348dcfa3c2c87172b1) |
| 2 | 42193740 | yes | 616583491194386321 | [`0xb37e…c7d93`](https://sepolia.basescan.org/tx/0xb37ef4d0b3c7ddac86411d12e9955fb8981b32ab331083b501edfa89bcdc7d93) |
| 3 | 42193741 | yes | 563107457901288747 | [`0x686b…3956`](https://sepolia.basescan.org/tx/0x686b9ca34cc36ce03c4fd62d429081f929a6aa893a87238a66515a58db9a3956) |
| 4 | 42193742 | yes | 516299209149614170 | [`0x7a51…dc07c`](https://sepolia.basescan.org/tx/0x7a5118553fbb571649b2c5a2dfa1ee832a90aee445628d37c3edc1777e4dc07c) |
| 5 | 42193743 | yes | 475094461379178682 | [`0xae6b…94b41`](https://sepolia.basescan.org/tx/0xae6ba4c4d25b2a6b44f13758f8393e456f10354f9e937ae9bb2b9a3ceaa94b41) |
| 6 | 42193744 | yes | 438633128302814958 | [`0x4bce…46a6b`](https://sepolia.basescan.org/tx/0x4bce13200500b5b23fdc1bd104774f951995ea2d3f560fb9345f7e26e3c46a6b) |

Sum of captured premium: `2609717747927282878` (≈ 2.6097 token1).

## On-chain reserve readback (current live state)

```bash
cast call --rpc-url "$BASE_SEPOLIA_RPC_URL" \
  0xf9664050d816d0cAD201B318A30E9D4C4eA270c4 \
  "getSmoothingReserve(bytes32)(uint128,uint128,uint48)" \
  0xcaa1b7d8d6f50c015e62d713f2f55154cd6dd6dad4bf3aeb966cdf8eec34577b
```

```text
reserve0      = 0
reserve1      = 2609717747927282878   # 2.6097e18 — matches the sum above, to the wei
lastDripBlock = 0                     # no drip has ever fired on this pool
```

```bash
# regime: stored vs decayed
getCurrentRegime   = 2   # last swap left the pool toxic
getEffectiveRegime = 0   # pressure has since decayed -> pool is quiet
```

What this proves:

- **Premium is escrowed, not paid straight through.** Each toxic swap emitted
  `PremiumCaptured` and grew the hook-held reserve; the per-swap captures sum
  exactly to the live on-chain `reserve1` with no rounding drift.
- **Capture is monotonic and decaying per swap** (0.6166 → 0.4386), consistent
  with the bounded fee surcharge being applied to a shrinking output as the
  pool moves.
- **Value is conserved on the capture side.** `reserve1 == Σ PremiumCaptured`,
  `reserve0 == 0` (one-sided flow), nothing minted or lost.

## Drip status (the remaining testnet leg)

`lastDripBlock = 0` and `getEffectiveRegime = 0`: the reserve is **stranded** in
a quiet pool. The drip release on testnet is intentionally **not yet executed**
because this exact reserve is staged for the autonomous Reactive CRON relay
(release with no swap), which is currently **on hold** pending a product
decision.

The drip mechanism itself is fully proven on real v4 infrastructure in the
fork test ([`base-mainnet-fork-smoothing-capture-drip.md`](base-mainnet-fork-smoothing-capture-drip.md)):
a quiet-regime swap releases exactly `dripBps` to in-range LPs via `donate`,
with `captured == dripped + remaining` hard-gated. On testnet the same release
fires on either (a) the Reactive relay, or (b) any organic quiet-regime swap
once the cooldown has elapsed.

## Reproduce

```bash
forge script script/reactive/BuildReserveBaseSepolia.s.sol \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" --broadcast --slow -vv
```
