# Directional Toxicity Shield

Directional Toxicity Shield is a prior-art-aware Uniswap v4 hook that applies a bounded directional dynamic LP fee. It tracks signed, decaying directional pressure per `PoolId`, raises fees when a swap continues harmful pressure, discounts counter-flow, and falls back to conservative behavior under low liquidity or quiet periods.

The base product is intentionally lean v4:

- no external oracle dependency
- pricing is local, deterministic, and bounded per `PoolId`
- hook permissions: `beforeInitialize`, `afterInitialize`, `beforeSwap`, `afterSwap`

It also ships an **opt-in** yield-smoothing layer (disabled by default). Pools that never call `configureSmoothing` keep the pure directional-fee behavior above with no custody and no return deltas. Pools that enable smoothing accept that the hook briefly holds the captured toxicity premium as ERC-6909 claims (`afterSwapReturnDelta`) between capture in toxic regimes and a rate-limited `donate()` drip back to in-range LPs in quiet regimes. This custody tradeoff is opt-in and documented in [docs/plans/2026-05-30-lp-yield-smoothing-design-draft.md](docs/plans/2026-05-30-lp-yield-smoothing-design-draft.md).

The implementation is scaffolded from the Uniswap Foundation v4 template and keeps the original helper scripts/tests available while the production hook lives in [src/DirectionalToxicityShield.sol](src/DirectionalToxicityShield.sol).

### Verify

```bash
forge fmt --check
forge build
forge test
```

### Onchain Test Gates

Stage 1 runs the directional scenario against a fresh local Foundry v4 deployment:

```bash
forge test --match-contract DirectionalToxicityShieldOnchainTest \
  --match-test test_stage1LocalFreshV4RunsDirectionalScenario -vvv
```

Stage 2 runs the same scenario on forks against canonical Uniswap v4 deployments:

```bash
forge test --fork-url https://mainnet.base.org \
  --match-contract DirectionalToxicityShieldOnchainTest \
  --match-test 'test_stage2*' -vvv

forge test --fork-url https://mainnet.unichain.org \
  --match-contract DirectionalToxicityShieldOnchainTest \
  --match-test 'test_stage2*' -vvv
```

Do not broadcast to testnet until both gates pass. Stage 3 target is Unichain Sepolia, using the official v4 `PoolManager` at `0x00B036B58a818B1BC34d502D3fE730Db729e62AC`. Use a funded keystore account and record the deployed hook address, pool id, token addresses, swap transactions, and explorer links before treating any testnet result as proof.

Stage 3 Unichain Sepolia scenario:

```bash
forge script script/testnet/UnichainSepoliaScenario.s.sol:UnichainSepoliaScenario \
  --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL"

forge script script/testnet/UnichainSepoliaScenario.s.sol:UnichainSepoliaScenario \
  --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL" \
  --broadcast
```

Set `DTS_HOOK_ADDRESS` when rerunning the scenario against an already deployed hook instead of deploying a new mined hook:

```bash
DTS_HOOK_ADDRESS=0xE7cd65413205e10B4005017F8d000a66E43970c0 \
forge script script/testnet/UnichainSepoliaScenario.s.sol:UnichainSepoliaScenario \
  --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL"
```

The latest Unichain Sepolia run is recorded in [deployments/unichain-sepolia-stage3-2026-05-30-smoothing.md](deployments/unichain-sepolia-stage3-2026-05-30-smoothing.md) (opt-in yield-smoothing + optimizer/via-IR enabled; supersedes the `-2026-05-30.md` hardening redeploy and the original `-2026-05-25.md` run).

Stage 3 Base Sepolia scenario uses the same mock-token flow against canonical v4 deployments:

```bash
forge script script/testnet/BaseSepoliaScenario.s.sol:BaseSepoliaScenario \
  --rpc-url "$BASE_SEPOLIA_RPC_URL"

forge script script/testnet/BaseSepoliaScenario.s.sol:BaseSepoliaScenario \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" \
  --broadcast
```

Base Sepolia USDC is optional for the MVP proof. Use the mock-token scenario first to verify hook mechanics, then add a USDC-paired demo only after confirming the current testnet USDC address and the deployer balance.

The latest Base Sepolia mock-token run is recorded in [deployments/base-sepolia-stage3-2026-05-30-smoothing.md](deployments/base-sepolia-stage3-2026-05-30-smoothing.md) (opt-in yield-smoothing + optimizer/via-IR enabled; supersedes the `-2026-05-30.md` hardening redeploy and the original `-2026-05-25.md` run).

### Simulation

```bash
forge script script/DirectionalToxicityShieldSimulation.s.sol:DirectionalToxicityShieldSimulation
```

### Backtests

```bash
forge script script/DirectionalToxicityShieldBacktest.s.sol:DirectionalToxicityShieldBacktest
```

The backtest harness compares Shield against modeled prior-art mechanisms: AsymmetricFeesHook/JDS previous-move Nezlobin, Anti-Toxicity Hook-style directional imbalance, Dynamic AMM Fees-style volatility/size pricing, DetoxHook-style oracle arbitrage capture, and VPIN-style volume imbalance. These are deterministic same-flow model backtests, not audited reimplementations of competitor contracts.

The simulation compares:

- static fee baseline
- plain last-move directional baseline
- JDS AsymmetricFeesHook-style previous-move fee skew, normalized to tick movement
- RegisGraptin Nezlobin side-skew model, using its `abs(tickDelta) * 750 / 1000` fee adjustment
- InfHook Nezlobin model, including its stateful dynamic-fee behavior when tick movement goes quiet
- Jaseempk NZ-Directional-Fee threshold model, normalized to ticks because the source implementation depends on oracle/liquidity-shaped `cDelta`
- deployed fixed-direction comparator: Clanker Static Fee Hook on Base (`0xDd5EeaFf7BD481AD55Db083062b13a3cdf0A68CC`), modeled from its verified source and an observed `PoolInitialized` fee pair of `10000/5000`
- Directional Toxicity Shield decaying pressure policy

It prints fee totals, max fee, and final pressure for deterministic one-direction, alternating-flow, and quiet-reset scenarios. The source-code comparators show why a plain Nezlobin hook is not enough by itself: some variants ignore tick sign, some retain stale fees without decay, and some need oracle/liquidity tuning that is outside this MVP. The deployed comparator is a fixed per-direction fee hook, not a signed pressure accumulator, so treat it as a live directional-fee reference point rather than a like-for-like product benchmark.

Source references:

- https://github.com/Jds-23/asymmetric-fees-hook
- https://github.com/RegisGraptin/Uniswap-Nezlobin-Hook
- https://github.com/emrhncvsgl/InfHook
- https://github.com/Jaseempk/NZ-Directional-Fee

### Deployment Dry Run

With local Anvil running:

```bash
forge script script/00_DeployHook.s.sol:DeployHookScript \
  --rpc-url http://127.0.0.1:8545 \
  --private-key <ANVIL_PRIVATE_KEY>
```

The deploy script mines a hook address for the MVP permission bits and deploys `DirectionalToxicityShield` with the configured v4 `PoolManager`.

### Requirements

This template is designed to work with Foundry (stable). If you are using Foundry Nightly, you may encounter compatibility issues. You can update your Foundry installation to the latest stable version by running:

```
foundryup
```

To set up the project, run the following commands in your terminal to install dependencies and run the tests:

```
forge install
forge test
```

### Local Development

Other than writing unit tests (recommended!), you can only deploy & test hooks on [anvil](https://book.getfoundry.sh/anvil/) locally. Scripts are available in the `script/` directory, which can be used to deploy hooks, create pools, provide liquidity and swap tokens. The scripts support both local `anvil` environment as well as running them directly on a production network.

### Executing locally with using **Anvil**:

1. Start Anvil (or fork a specific chain using anvil):

```bash
anvil
```

or

```bash
anvil --fork-url <YOUR_RPC_URL>
```

2. Execute scripts:

```bash
forge script script/00_DeployHook.s.sol \
    --rpc-url http://localhost:8545 \
    --private-key <PRIVATE_KEY> \
    --broadcast
```

### Using **RPC URLs** (actual transactions):

:::info
It is best to not store your private key even in .env or enter it directly in the command line. Instead use the `--account` flag to select your private key from your keystore.
:::

### Follow these steps if you have not stored your private key in the keystore:

<details>

1. Add your private key to the keystore:

```bash
cast wallet import <SET_A_NAME_FOR_KEY> --interactive
```

2. You will prompted to enter your private key and set a password, fill and press enter:

```
Enter private key: <YOUR_PRIVATE_KEY>
Enter keystore password: <SET_NEW_PASSWORD>
```

You should see this:

```
`<YOUR_WALLET_PRIVATE_KEY_NAME>` keystore was saved successfully. Address: <YOUR_WALLET_ADDRESS>
```

::: warning
Use `history -c` to clear your command history.
:::

</details>

1. Execute scripts:

```bash
forge script script/00_DeployHook.s.sol \
    --rpc-url <YOUR_RPC_URL> \
    --account <YOUR_WALLET_PRIVATE_KEY_NAME> \
    --sender <YOUR_WALLET_ADDRESS> \
    --broadcast
```

You will prompted to enter your wallet password, fill and press enter:

```
Enter keystore password: <YOUR_PASSWORD>
```

### Key Modifications to note:

1. Update the `token0` and `token1` addresses in the `BaseScript.sol` file to match the tokens you want to use in the network of your choice for sepolia and mainnet deployments.
2. Update the `token0Amount` and `token1Amount` in the `CreatePoolAndAddLiquidity.s.sol` file to match the amount of tokens you want to provide liquidity with.
3. Update the `token0Amount` and `token1Amount` in the `AddLiquidity.s.sol` file to match the amount of tokens you want to provide liquidity with.
4. Update the `amountIn` and `amountOutMin` in the `Swap.s.sol` file to match the amount of tokens you want to swap.

### Verifying the hook contract

```bash
forge verify-contract \
  --rpc-url <URL> \
  --chain <CHAIN_NAME_OR_ID> \
  # Generally etherscan
  --verifier <Verification_Provider> \
  # Use --etherscan-api-key <ETHERSCAN_API_KEY> if you are using etherscan
  --verifier-api-key <Verification_Provider_API_KEY> \
  --constructor-args <ABI_ENCODED_ARGS> \
  --num-of-optimizations <OPTIMIZER_RUNS> \
  <Contract_Address> \
  <path/to/Contract.sol:ContractName>
  --watch
```

### Troubleshooting

<details>

#### Permission Denied

When installing dependencies with `forge install`, Github may throw a `Permission Denied` error

Typically caused by missing Github SSH keys, and can be resolved by following the steps [here](https://docs.github.com/en/github/authenticating-to-github/connecting-to-github-with-ssh)

Or [adding the keys to your ssh-agent](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent#adding-your-ssh-key-to-the-ssh-agent), if you have already uploaded SSH keys

#### Anvil fork test failures

Some versions of Foundry may limit contract code size to ~25kb, which could prevent local tests to fail. You can resolve this by setting the `code-size-limit` flag

```
anvil --code-size-limit 40000
```

#### Hook deployment failures

Hook deployment failures are caused by incorrect flags or incorrect salt mining

1. Verify the flags are in agreement:
   - `getHookCalls()` returns the correct flags
   - `flags` provided to `HookMiner.find(...)`
2. Verify salt mining is correct:
   - In **forge test**: the _deployer_ for: `new Hook{salt: salt}(...)` and `HookMiner.find(deployer, ...)` are the same. This will be `address(this)`. If using `vm.prank`, the deployer will be the pranking address
   - In **forge script**: the deployer must be the CREATE2 Proxy: `0x4e59b44847b379578588920cA78FbF26c0B4956C`
     - If anvil does not have the CREATE2 deployer, your foundry may be out of date. You can update it with `foundryup`

</details>

### Additional Resources

- [Uniswap v4 docs](https://docs.uniswap.org/contracts/v4/overview)
- [v4-periphery](https://github.com/uniswap/v4-periphery)
- [v4-core](https://github.com/uniswap/v4-core)
- [v4-by-example](https://v4-by-example.org)
