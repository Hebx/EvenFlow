# Development & Testnet Guide

Detailed build, test-gate, deployment, and troubleshooting reference for Directional Toxicity Shield. The top-level [README](../README.md) is the product overview; this is the contributor handbook.

## Requirements

Built with Foundry (stable). On Foundry Nightly you may hit compatibility issues — update with `foundryup`.

```bash
forge install
forge test
```

Toolchain: Solidity `0.8.30`, `evm_version = cancun`, optimizer on (`200` runs), `via_ir = true`.

## Test gates

The suite is staged from local determinism up to real-infrastructure forks. Don't broadcast to testnet until the local and fork gates pass.

### Stage 1 — local fresh v4

```bash
forge test --match-contract DirectionalToxicityShieldOnchainTest \
  --match-test test_stage1LocalFreshV4RunsDirectionalScenario -vvv
```

### Stage 2 — canonical v4 forks

```bash
forge test --fork-url https://mainnet.base.org \
  --match-contract DirectionalToxicityShieldOnchainTest --match-test 'test_stage2*' -vvv

forge test --fork-url https://mainnet.unichain.org \
  --match-contract DirectionalToxicityShieldOnchainTest --match-test 'test_stage2*' -vvv
```

### Stage 3 — testnet scenarios

Targets the official v4 `PoolManager` on each testnet (Unichain Sepolia `0x00B036B58a818B1BC34d502D3fE730Db729e62AC`). Use a funded keystore account and record the deployed hook address, pool id, token addresses, swap txs, and explorer links before treating any result as proof.

```bash
# Unichain Sepolia
forge script script/testnet/UnichainSepoliaScenario.s.sol:UnichainSepoliaScenario \
  --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL" [--broadcast]

# Base Sepolia (same mock-token flow)
forge script script/testnet/BaseSepoliaScenario.s.sol:BaseSepoliaScenario \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" [--broadcast]
```

Re-run against an already-deployed hook instead of mining a new one by setting `DTS_HOOK_ADDRESS`. Latest recorded runs live under [../deployments/](../deployments/) (the `-smoothing` files are current; they supersede the earlier hardening and original runs).

### Stage 4 — live-production comparison

Deploys the Shield against the real canonical Base mainnet v4 `PoolManager` (`0x498581fF718922c3f8e6A244956aF099B2652b2b`) and proves the live Clanker static-fee hook (`0xDd5EeaFf7BD481AD55Db083062b13a3cdf0A68CC`, 12,558 bytes) is co-located on it, then contrasts adaptive-vs-static behavior on identical flow.

```bash
# Behavioral contrast runs locally (CI-safe; live-hook assertion skipped off-fork)
forge test --match-contract DirectionalToxicityShieldMainnetComparisonTest -vv

# Full proof against real Base mainnet infrastructure
forge test --match-contract DirectionalToxicityShieldMainnetComparisonTest \
  --fork-url "$BASE_MAINNET_RPC_URL" -vv
```

### Reactive layer

```bash
forge test --match-path 'test/reactive/*.sol'
forge test --match-path 'test/ShieldReactiveForkE2E.t.sol'
```

Reactive deploy/diagnosis lessons worth keeping in mind: classic reactive proxies inject `rvm_id`, so callback auth must check it; and reactive contracts whose constructor calls `subscribe()` must be deployed with `cast send --create` rather than `forge script` (the local revm lacks the `0x64` precompile).

## Simulation & backtests

```bash
forge script script/DirectionalToxicityShieldSimulation.s.sol:DirectionalToxicityShieldSimulation
forge script script/DirectionalToxicityShieldBacktest.s.sol:DirectionalToxicityShieldBacktest
```

The harness contrasts the Shield's decaying-pressure policy against modeled prior art on deterministic same-flow scenarios:

- static fee baseline; plain last-move directional baseline
- JDS AsymmetricFeesHook previous-move skew (normalized to tick movement)
- RegisGraptin Nezlobin side-skew (`abs(tickDelta) * 750 / 1000`)
- InfHook Nezlobin model (stateful behavior when movement goes quiet)
- Jaseempk NZ-Directional-Fee threshold model (normalized to ticks; source depends on oracle/liquidity-shaped `cDelta`)
- Clanker Static Fee Hook on Base, modeled from verified source (observed `10000/5000` fee pair)

These are deterministic same-flow model backtests, **not** audited reimplementations of competitor contracts. They show why a plain Nezlobin hook isn't enough alone: some variants ignore tick sign, some retain stale fees without decay, some need oracle/liquidity tuning. Source references:

- <https://github.com/Jds-23/asymmetric-fees-hook>
- <https://github.com/RegisGraptin/Uniswap-Nezlobin-Hook>
- <https://github.com/emrhncvsgl/InfHook>
- <https://github.com/Jaseempk/NZ-Directional-Fee>

## Deployment

The deploy script mines a CREATE2 salt for the hook permission bits and deploys against the configured v4 `PoolManager`.

```bash
# Local dry run (Anvil)
anvil    # optionally: anvil --fork-url <RPC> --code-size-limit 40000
forge script script/00_DeployHook.s.sol:DeployHookScript \
  --rpc-url http://127.0.0.1:8545 --private-key <ANVIL_PRIVATE_KEY> --broadcast
```

### Keystore-based broadcast (preferred over raw keys)

```bash
# One-time: import a key
cast wallet import <KEY_NAME> --interactive

# Deploy
forge script script/00_DeployHook.s.sol:DeployHookScript \
  --rpc-url <RPC_URL> --account <KEY_NAME> --sender <ADDRESS> --broadcast
```

Avoid storing private keys in `.env` or on the command line; prefer `--account`. Clear shell history with `history -c` if you ever paste a secret.

### Pool / liquidity / swap scripts

The `script/` directory also has pool-creation, add-liquidity, and swap scripts (local Anvil or live networks). Update token addresses in `BaseScript.sol`, liquidity amounts in `CreatePoolAndAddLiquidity.s.sol` / `AddLiquidity.s.sol`, and swap amounts in `Swap.s.sol` for your target.

### Verify a deployed hook

```bash
forge verify-contract \
  --rpc-url <URL> --chain <CHAIN_NAME_OR_ID> \
  --verifier <PROVIDER> --verifier-api-key <API_KEY> \
  --constructor-args <ABI_ENCODED_ARGS> \
  --num-of-optimizations 200 \
  <CONTRACT_ADDRESS> src/DirectionalToxicityShield.sol:DirectionalToxicityShield --watch
```

## Troubleshooting

**`forge install` Permission Denied** — usually missing GitHub SSH keys. See [GitHub SSH setup](https://docs.github.com/en/authentication/connecting-to-github-with-ssh).

**Anvil fork test failures** — contract code-size limit. Run `anvil --code-size-limit 40000`.

**Hook deployment failures** — almost always flag or salt-mining mismatch:

- `getHookCalls()` flags must match the `flags` passed to `HookMiner.find(...)`.
- The deployer in `new Hook{salt: salt}(...)` and `HookMiner.find(deployer, ...)` must be the same address. In `forge test` that's `address(this)` (or the prank address). In `forge script` it must be the CREATE2 proxy `0x4e59b44847b379578588920cA78FbF26c0B4956C` — update Foundry with `foundryup` if Anvil lacks it.

**Deploying reactive contracts** — `forge script` reverts with a generic `Failure` because its local revm lacks Reactive's `0x64` precompile that `subscribe()` calls in the constructor. Deploy with `cast send --create` so the constructor only runs on the real Reactive node.
