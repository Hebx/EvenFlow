# Base Sepolia Stage 3 Run - 2026-05-25

Network: Base Sepolia
Chain ID: `84532`
Explorer: `https://sepolia.basescan.org`
Deployer: `0x46Ca9120Ea33E7AF921Db0a230831CB08AeB2910`

## Canonical v4 addresses

- PoolManager: `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`
- PositionManager: `0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80`
- Hookmate V4 SwapRouter: `0x71cD4Ea054F9Cb3D3BF6251A00673303411A7DD9`
- Permit2: `0x000000000022D473030F116dDEE9F6B43aC78BA3`

## Deployed contracts

- DirectionalToxicityShield: `0xdf1b6843711039408b3b87572F9E9830BCcaF0C0`
- token0 / DTS-A: `0x1c76858708246f146A584C1DF8761f0e7377ceA8`
- token1 / DTS-B: `0x468E4bbC096Ee6E00801fa2993f01A9b956885BC`
- PoolId: `0x9468fe871c2dd7581239053dc54d37466d1d2f5ad88246a39606867549aa1415`

This run used mock ERC-20 test tokens only. Base Sepolia USDC was not used.

## Final hook state

Read from `getDirectionalState(poolId)` after pool initialization, liquidity mint, and two same-direction swaps:

- `referenceTick`: `0`
- `lastTick`: `394`
- `pressure`: `500`
- `lastUpdateTime`: `1779689754`
- `lastFee`: `3500`
- `regime`: `2`

This matches the expected Directional Toxicity Shield behavior for the scenario: the first swap uses the calm base fee, then pressure accumulates and the second same-direction swap receives the bounded higher fee.

## Transactions

- Hook deployment: `0x5011f6128fb0d53872abbbef48eea5551cb570f1b1751fedf96f82ae60caae7c`
- Token A deployment: `0x102dcb754399ecaa0c35aec54cd26df2925f83eadc2249aababee46e122cf05b`
- Token B deployment: `0xc271f94bcef3cd06fd1db8cba31f3a36bd49af64f63598eccc9124812d826f8e`
- Pool initialization: `0x9b3db87a09e8d00493949b30c960f3461d50ca8d8225ed319ea9e19b954257b1`
- Liquidity mint: `0x65df8d73dce70ee76b8dc430053f4beefdfd376bdf1bd61e1b35b4e519ef9e9c`
- First swap: `0xb4e14c84aea33a3e86445f5782210183c1ebf443d569abd09c7000fab75363d6`
- Second swap: `0xf4935367d81095af934300ddfdb4a5bf58524395fce7bcbc4585de9ad0fca60d`

## Verification commands

```bash
forge script script/testnet/BaseSepoliaScenario.s.sol:BaseSepoliaScenario \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" \
  --broadcast

cast call --rpc-url "$BASE_SEPOLIA_RPC_URL" \
  0xdf1b6843711039408b3b87572F9E9830BCcaF0C0 \
  "getDirectionalState(bytes32)(int24,int24,int56,uint40,uint24,uint8)" \
  0x9468fe871c2dd7581239053dc54d37466d1d2f5ad88246a39606867549aa1415
```

Foundry broadcast artifact:

```text
broadcast/BaseSepoliaScenario.s.sol/84532/run-latest.json
```

## Existing-hook reuse check

The scenario was also rerun in dry-run mode with `DTS_HOOK_ADDRESS=0xdf1b6843711039408b3b87572F9E9830BCcaF0C0` to confirm later scenario runs can target the already deployed hook instead of deploying another mined hook.

Dry-run result:

- Hook reused: `0xdf1b6843711039408b3b87572F9E9830BCcaF0C0`
- PoolId: `0xa5d2d0ea1f66722a9621fbde1370e6b44554e4c8ed3732a830b84d8d8010ca4b`
- `firstFee`: `3000`
- `secondFee`: `3500`
- `pressure`: `500`
- `lastTick`: `394`
- `regime`: `2`

Command:

```bash
DTS_HOOK_ADDRESS=0xdf1b6843711039408b3b87572F9E9830BCcaF0C0 \
forge script script/testnet/BaseSepoliaScenario.s.sol:BaseSepoliaScenario \
  --rpc-url "$BASE_SEPOLIA_RPC_URL"
```
