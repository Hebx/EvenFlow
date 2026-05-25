# Unichain Sepolia Stage 3 Run - 2026-05-25

Network: Unichain Sepolia
Chain ID: `1301`
Explorer: `https://sepolia.uniscan.xyz`
Deployer: `0x46Ca9120Ea33E7AF921Db0a230831CB08AeB2910`

## Canonical v4 Contracts

- `PoolManager`: `0x00B036B58a818B1BC34d502D3fE730Db729e62AC`
- `PositionManager`: `0xf969Aee60879C54bAAed9F3eD26147Db216Fd664`
- `Hookmate V4 SwapRouter`: `0x9cD2b0a732dd5e023a5539921e0FD1c30E198Dba`

## Deployed Scenario Contracts

- `DirectionalToxicityShield`: `0xE7cd65413205e10B4005017F8d000a66E43970c0`
- `token0`: `0x1E7A098e197691FeE6eCb48765A84F4faa25A6cc`
- `token1`: `0x6A2e0956c27ff893b90350B80686Fc84E8e53e3D`
- `PoolId`: `0xadfc4dbdd5e6aee6d4433b958552df2b2054435d3ecaee13a93cac9e7314ecbb`

## Result

Two same-direction swaps were executed against a dynamic-fee hooked pool.

- First applied fee: `3000`
- Second applied fee: `3500`
- Final pressure: `500`
- Final tick: `394`
- Final regime: `2`

Readback command:

```bash
cast call --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL" \
  0xE7cd65413205e10B4005017F8d000a66E43970c0 \
  "getDirectionalState(bytes32)(int24,int24,int56,uint40,uint24,uint8)" \
  0xadfc4dbdd5e6aee6d4433b958552df2b2054435d3ecaee13a93cac9e7314ecbb
```

Readback output:

```text
0
394
500
1779688773
3500
2
```

## Key Transactions

- Hook deployment: `https://sepolia.uniscan.xyz/tx/0x4aa6801f8e4b13e3239e637b9a095ba6ee77cba787ab2c7fce48e1479050497b`
- Token A deployment: `https://sepolia.uniscan.xyz/tx/0x05bb336289d6ae010ab158db219d4cf901926e32c88911f4f9264bc151405d4c`
- Token B deployment: `https://sepolia.uniscan.xyz/tx/0x71227818cf01b7e5a6e10ffc69dac21c7ce449482874aa11154894eb6e52006c`
- Pool initialization: `https://sepolia.uniscan.xyz/tx/0x891cee4fc333157104544241f4e4e25aa1d09feff877d895781bdde6e0e25228`
- Liquidity mint: `https://sepolia.uniscan.xyz/tx/0xdb70d616c8d6a5b211ead7d2db474bfe9fca0585273f303ad86170650f55d05d`
- First swap: `https://sepolia.uniscan.xyz/tx/0x75f137d06649251677e4a2c579648676006755c694199be04797bdd6c1973605`
- Second swap: `https://sepolia.uniscan.xyz/tx/0x1336c699cf9ed141ccb4fcd39ec75a6913735c48ff6106b0a2ba1051903f0bcc`

Broadcast artifact:

```text
broadcast/UnichainSepoliaScenario.s.sol/1301/run-latest.json
```
