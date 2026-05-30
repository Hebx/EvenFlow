# Base Sepolia Stage 3 Run - 2026-05-30 (yield-smoothing + optimizer)

Network: Base Sepolia
Chain ID: `84532`
Explorer: `https://sepolia.basescan.org`
Deployer: `0x46Ca9120Ea33E7AF921Db0a230831CB08AeB2910`

> Redeploy after the opt-in LP yield-smoothing layer (premium capture + rate-limited
> drip, custody as ERC-6909 claims) **and** enabling the Solidity optimizer + via-IR
> in `foundry.toml`. Supersedes `base-sepolia-stage3-2026-05-30.md`. Matches the
> Unichain Sepolia redeploy in `unichain-sepolia-stage3-2026-05-30-smoothing.md`.
>
> The smoothing feature pushed unoptimized runtime bytecode to 24,951 B — 375 B over
> the EIP-170 24,576 B cap. Enabling the optimizer (`runs=200`) drops runtime to
> **10,172 B**. On-chain code size verified at 10,172 B. The new bytecode mines a new
> CREATE2 hook address.

## Canonical v4 Contracts

Resolved via `AddressConstants` for chain `84532`.

- `PoolManager`: `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`
- `PositionManager`: `0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80`
- `Hookmate V4 SwapRouter`: `0x71cD4Ea054F9Cb3D3BF6251A00673303411A7DD9`

## Deployed Scenario Contracts

- `DirectionalToxicityShield`: `0x538c73F7731d0D4bCEa6ee264955F66c5bd830c4` (runtime 10,172 B)
- `token0`: `0x05eB8BDAa01E2D59e94c1EbF8a162A317d379DeD`
- `token1`: `0x53843729cA17931AC56ee4c3A25946bCc5203b7e`
- `PoolId`: `0xc7d8875e682a92581cf840c95445123ee0127c862b58d518454f39c269a99c7b`

## Result

Two same-direction swaps were executed against a dynamic-fee hooked pool. Each
swap landed in its own block, so directional pressure accumulated.

- First applied fee: `3000`
- Second applied fee: `3500`
- Final pressure: `198`
- Final tick: `394`
- Final regime: `1`

Readback command:

```bash
cast call --rpc-url "$BASE_SEPOLIA_RPC_URL" \
  0x538c73F7731d0D4bCEa6ee264955F66c5bd830c4 \
  "getDirectionalState(bytes32)(int24,int24,int56,uint40,uint24,uint8)" \
  0xc7d8875e682a92581cf840c95445123ee0127c862b58d518454f39c269a99c7b
```

Readback output:

```text
0
394
198
1780105834
3500
1
```

## Key Transactions

- Hook deployment: `https://sepolia.basescan.org/tx/0x2480af70d9f5c516afc0b8fa4b50dad4dccc7106200d61d55c742427154de531`
- Token A deployment: `https://sepolia.basescan.org/tx/0x9fe1b6e76a6c854b06b417804684f00efcc9f40655175e5201ed0784a88895b8`
- Token B deployment: `https://sepolia.basescan.org/tx/0x1d552238ea278537253b97b154912bf1afff7621d28f548ada6bc1992a8537d2`
- Pool initialization: `https://sepolia.basescan.org/tx/0xe3de9ac38a123dda14e0769740fd18a2f3b37061ec5e1779df6832f4df7a60f7`
- Liquidity mint: `https://sepolia.basescan.org/tx/0xc4e2e8d8e12c9691754bdf41aa78429efc5ccb8e99b122d754822f366c6a790f`
- First swap: `https://sepolia.basescan.org/tx/0x1d536f71fb943b9976e857327e13e90ac194fb756ab6c95a8b2e24583298a339`
- Second swap: `https://sepolia.basescan.org/tx/0xab759b30b73a700b8ba4aeb45700481a0004937b11a5e040090e69cb1a4dfb1f`

Broadcast artifact:

```text
broadcast/BaseSepoliaScenario.s.sol/84532/run-latest.json
```
