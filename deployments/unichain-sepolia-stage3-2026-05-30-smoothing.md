# Unichain Sepolia Stage 3 Run - 2026-05-30 (yield-smoothing + optimizer)

Network: Unichain Sepolia
Chain ID: `1301`
Explorer: `https://sepolia.uniscan.xyz`
Deployer: `0x46Ca9120Ea33E7AF921Db0a230831CB08AeB2910`

> Redeploy after the opt-in LP yield-smoothing layer (premium capture + rate-limited
> drip, custody as ERC-6909 claims) **and** enabling the Solidity optimizer + via-IR
> in `foundry.toml`. Supersedes `unichain-sepolia-stage3-2026-05-30.md`.
>
> The smoothing feature pushed unoptimized runtime bytecode to 24,951 B — 375 B over
> the EIP-170 24,576 B cap — making the hook undeployable despite a green test suite
> (the test EVM does not enforce the cap). Enabling the optimizer (`runs=200`) drops
> runtime to **10,172 B**. The on-chain code size was verified at 10,172 B.
> The new bytecode mines a new CREATE2 hook address.

## Canonical v4 Contracts

- `PoolManager`: `0x00B036B58a818B1BC34d502D3fE730Db729e62AC`
- `PositionManager`: `0xf969Aee60879C54bAAed9F3eD26147Db216Fd664`
- `Hookmate V4 SwapRouter`: `0x9cD2b0a732dd5e023a5539921e0FD1c30E198Dba`

## Deployed Scenario Contracts

- `DirectionalToxicityShield`: `0x3c3B588676879f8858E65156787B223172A130c4` (runtime 10,172 B)
- `token0`: `0x03656A77cd0d4f3Ee0BB537D89f0a2a22d9593b0`
- `token1`: `0x9FF9245efF65CD37493d5f73391Df8E23ED7E51E`
- `PoolId`: `0x4e921f8c8e2e06f102d0301a07e5c38f931d12d64adb898b5b7737a0815c5b0e`

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
cast call --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL" \
  0x3c3B588676879f8858E65156787B223172A130c4 \
  "getDirectionalState(bytes32)(int24,int24,int56,uint40,uint24,uint8)" \
  0x4e921f8c8e2e06f102d0301a07e5c38f931d12d64adb898b5b7737a0815c5b0e
```

Readback output:

```text
0
394
198
1780105819
3500
1
```

## Key Transactions

- Hook deployment: `https://sepolia.uniscan.xyz/tx/0xb15a9bd7d4b4450895e1a7f95f951eeb13f051f4888cdaf5f57b0d2dcdeadd6f`
- Token A deployment: `https://sepolia.uniscan.xyz/tx/0xa5806ffffdcf8dbbdd0828a043ecc5137a20d1b2436699ac08a15b4c258b21d6`
- Token B deployment: `https://sepolia.uniscan.xyz/tx/0x3a63f0cc1357b1b198cbfbed95c4a84a4def961c8367e2405f01481abdb66afb`
- Pool initialization: `https://sepolia.uniscan.xyz/tx/0xefb9957f15d74d207594a66bb9cca558d3e9add75759d1c264745f0ee4e85ae5`
- Liquidity mint: `https://sepolia.uniscan.xyz/tx/0xe59c86b273c5d381975f79d154323565713a093174b142775102df4311adef7f`
- First swap: `https://sepolia.uniscan.xyz/tx/0xa2e168a4545ba47dedf599197cb4cf54cd05f58a16fb1944f48d15a33968009c`
- Second swap: `https://sepolia.uniscan.xyz/tx/0x042041544fcbfd68181c98856f9c9eb8d209f09344e89732eff55c8a48f8db85`

Broadcast artifact:

```text
broadcast/UnichainSepoliaScenario.s.sol/1301/run-latest.json
```
