// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {AddressConstants} from "hookmate/constants/AddressConstants.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {DirectionalToxicityShield} from "../../src/DirectionalToxicityShield.sol";
import {ShieldReactiveExecutor} from "../../src/reactive/ShieldReactiveExecutor.sol";
import {IDirectionalToxicityShield} from "../../src/reactive/IDirectionalToxicityShield.sol";


import {TestnetScenarioMockERC20} from "../testnet/TestnetDirectionalScenario.sol";

/// @notice Phase 3, destination side (Base Sepolia, chain 84532).
///
/// Deploys the upgraded (Phase 1) DirectionalToxicityShield with a freshly mined
/// CREATE2 address, stands up a pool + full-range liquidity, enables smoothing,
/// then deploys the ShieldReactiveExecutor and wires it as the hook's reactive
/// executor and registers the pool key.
///
/// Env:
///  - DEPLOYER_PRIVATE_KEY (broadcaster, also executor owner)
///
/// Deploy ordering: the executor and Lasna controller have a mutual address
/// dependency, broken with a set-once `controller`. Run this script first
/// (controller unset), then deploy the controller on Lasna pointing at this
/// executor, then call `executor.setController(controller)` to lock the wiring.
/// While unset, no callback can pass authorization.
///
/// The Base Sepolia callback proxy is fixed (origins-and-destinations table):
///   0xa6eA49Ed671B8a4dfCDd34E36b7a75Ac79B8A5a6
contract DeployReactiveDestinationBaseSepolia is Script {
    using PoolIdLibrary for PoolKey;

    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint160 private constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    address private constant CALLBACK_PROXY = 0xa6eA49Ed671B8a4dfCDd34E36b7a75Ac79B8A5a6;

    function run() external {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "wrong chain: expected Base Sepolia 84532");

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        IPoolManager poolManager = IPoolManager(AddressConstants.getPoolManagerAddress(block.chainid));
        IPositionManager positionManager = IPositionManager(AddressConstants.getPositionManagerAddress(block.chainid));
        IPermit2 permit2 = IPermit2(AddressConstants.getPermit2Address());
        IUniswapV4Router04 swapRouter =
            IUniswapV4Router04(payable(AddressConstants.getV4SwapRouterAddress(block.chainid)));

        vm.startBroadcast(pk);

        // 1. Deploy upgraded hook (mine CREATE2 flags).
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory ctorArgs = abi.encode(poolManager);
        (address hookAddr, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(DirectionalToxicityShield).creationCode, ctorArgs);
        DirectionalToxicityShield hook = new DirectionalToxicityShield{salt: salt}(poolManager);
        require(address(hook) == hookAddr, "hook addr mismatch");

        // 2. Tokens + pool + liquidity.
        TestnetScenarioMockERC20 tokenA = new TestnetScenarioMockERC20("DTS Reactive A", "DTSR-A", 18);
        TestnetScenarioMockERC20 tokenB = new TestnetScenarioMockERC20("DTS Reactive B", "DTSR-B", 18);
        tokenA.mint(deployer, 10_000_000 ether);
        tokenB.mint(deployer, 10_000_000 ether);

        (Currency c0, Currency c1) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));
        PoolKey memory key = PoolKey({
            currency0: c0, currency1: c1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 60, hooks: IHooks(hook)
        });

        _approve(tokenA, tokenB, permit2, positionManager, poolManager, swapRouter);
        // Initialize directly via the PoolManager so the hook records the
        // DEPLOYER as the pool configurer (not the PositionManager). The hook's
        // _afterInitialize captures msg.sender as the configurer, which gates
        // configureSmoothing / setReactiveExecutor below.
        poolManager.initialize(key, SQRT_PRICE_1_1);
        _addLiquidity(positionManager, key, deployer);

        // 3. Enable smoothing so escrow accrues on toxic flow.
        hook.configureSmoothing(
            key, DirectionalToxicityShield.SmoothingConfig({enabled: true, dripBlockInterval: 5, dripBps: 2000})
        );

        // 4. Deploy executor + wire it. Controller is set later (set-once) once
        // the Lasna controller address is known.
        ShieldReactiveExecutor executor =
            new ShieldReactiveExecutor(CALLBACK_PROXY, IDirectionalToxicityShield(address(hook)), deployer);
        hook.setReactiveExecutor(key, address(executor));
        executor.registerPool(key);

        vm.stopBroadcast();

        PoolId poolId = key.toId();
        console2.log("network", "base-sepolia");
        console2.log("deployer", deployer);
        console2.log("hook", address(hook));
        console2.log("executor", address(executor));
        console2.log("callbackProxy", address(CALLBACK_PROXY));
        console2.log("token0", Currency.unwrap(c0));
        console2.log("token1", Currency.unwrap(c1));
        console2.logBytes32(PoolId.unwrap(poolId));
        console2.log(
            "NEXT: deploy ShieldReactiveController on Lasna with this hook+executor+poolId, then call executor.setController(controller)."
        );
    }

    function _approve(
        TestnetScenarioMockERC20 a,
        TestnetScenarioMockERC20 b,
        IPermit2 permit2,
        IPositionManager pm,
        IPoolManager poolManager,
        IUniswapV4Router04 router
    ) private {
        a.approve(address(permit2), type(uint256).max);
        b.approve(address(permit2), type(uint256).max);
        a.approve(address(router), type(uint256).max);
        b.approve(address(router), type(uint256).max);
        permit2.approve(address(a), address(pm), type(uint160).max, type(uint48).max);
        permit2.approve(address(b), address(pm), type(uint160).max, type(uint48).max);
        permit2.approve(address(a), address(poolManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(b), address(poolManager), type(uint160).max, type(uint48).max);
    }

    function _addLiquidity(IPositionManager pm, PoolKey memory key, address recipient) private {
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        uint128 liquidity = 100 ether;
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidity
        );
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP), uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(key, tickLower, tickUpper, liquidity, a0 + 1, a1 + 1, recipient, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, recipient);
        params[3] = abi.encode(key.currency1, recipient);
        pm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
    }
}
