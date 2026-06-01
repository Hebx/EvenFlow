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

abstract contract TestnetDirectionalScenario is Script {
    using PoolIdLibrary for PoolKey;

    uint160 private constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    struct TestnetContracts {
        IPermit2 permit2;
        IPoolManager poolManager;
        IPositionManager positionManager;
        IUniswapV4Router04 swapRouter;
    }

    struct ScenarioResult {
        DirectionalToxicityShield hook;
        address token0;
        address token1;
        bytes32 poolId;
        uint24 firstFee;
        uint24 secondFee;
        int56 pressure;
        int24 lastTick;
        uint8 regime;
    }

    function _runScenario(uint256 expectedChainId, string memory networkName) internal {
        require(block.chainid == expectedChainId, "Scenario: unexpected chain id");

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        TestnetContracts memory contracts_ = _testnetContracts();

        vm.startBroadcast(deployerPrivateKey);
        ScenarioResult memory result = _executeDirectionalRun(contracts_, deployer);
        vm.stopBroadcast();

        _logResult(networkName, deployer, contracts_, result);
    }

    function _testnetContracts() private view returns (TestnetContracts memory contracts_) {
        contracts_ = TestnetContracts({
            permit2: IPermit2(AddressConstants.getPermit2Address()),
            poolManager: IPoolManager(AddressConstants.getPoolManagerAddress(block.chainid)),
            positionManager: IPositionManager(AddressConstants.getPositionManagerAddress(block.chainid)),
            swapRouter: IUniswapV4Router04(payable(AddressConstants.getV4SwapRouterAddress(block.chainid)))
        });
    }

    function _executeDirectionalRun(TestnetContracts memory contracts_, address deployer)
        private
        returns (ScenarioResult memory result)
    {
        address existingHook = vm.envOr("DTS_HOOK_ADDRESS", address(0));
        result.hook = _deployOrUseHook(contracts_.poolManager, existingHook);
        (TestnetScenarioMockERC20 tokenA, TestnetScenarioMockERC20 tokenB) = _deployTokens(deployer);
        _approveTokens(tokenA, tokenB, contracts_);

        PoolKey memory poolKey = _poolKey(tokenA, tokenB, result.hook);
        result.poolId = PoolId.unwrap(poolKey.toId());
        result.token0 = Currency.unwrap(poolKey.currency0);
        result.token1 = Currency.unwrap(poolKey.currency1);

        _initializePoolAndAddLiquidity(contracts_.positionManager, poolKey, deployer);
        _swapExactIn(contracts_.swapRouter, poolKey, false, deployer);
        result.firstFee = result.hook.getDirectionalState(PoolId.wrap(result.poolId)).lastFee;
        _swapExactIn(contracts_.swapRouter, poolKey, false, deployer);

        DirectionalToxicityShield.DirectionalState memory state =
            result.hook.getDirectionalState(PoolId.wrap(result.poolId));
        result.secondFee = state.lastFee;
        result.pressure = state.pressure;
        result.lastTick = state.lastTick;
        result.regime = uint8(state.regime);
    }

    function _logResult(
        string memory networkName,
        address deployer,
        TestnetContracts memory contracts_,
        ScenarioResult memory result
    ) private pure {
        console2.log("network", networkName);
        console2.log("deployer", deployer);
        console2.log("poolManager", address(contracts_.poolManager));
        console2.log("positionManager", address(contracts_.positionManager));
        console2.log("swapRouter", address(contracts_.swapRouter));
        console2.log("hook", address(result.hook));
        console2.log("token0", result.token0);
        console2.log("token1", result.token1);
        console2.logBytes32(result.poolId);
        console2.log("firstFee", result.firstFee);
        console2.log("secondFee", result.secondFee);
        console2.log("pressure", int256(result.pressure));
        console2.log("lastTick", int256(result.lastTick));
        console2.log("regime", uint256(result.regime));
    }

    function _deployOrUseHook(IPoolManager poolManager, address existingHook)
        private
        returns (DirectionalToxicityShield hook)
    {
        if (existingHook != address(0)) {
            require(existingHook.code.length > 0, "Scenario: existing hook has no code");
            return DirectionalToxicityShield(existingHook);
        }

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(poolManager);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(DirectionalToxicityShield).creationCode, constructorArgs);

        hook = new DirectionalToxicityShield{salt: salt}(poolManager);
        require(address(hook) == hookAddress, "Scenario: hook address mismatch");
    }

    function _deployTokens(address deployer)
        private
        returns (TestnetScenarioMockERC20 tokenA, TestnetScenarioMockERC20 tokenB)
    {
        tokenA = new TestnetScenarioMockERC20("DTS Test Token A", "DTS-A", 18);
        tokenB = new TestnetScenarioMockERC20("DTS Test Token B", "DTS-B", 18);
        tokenA.mint(deployer, 10_000_000 ether);
        tokenB.mint(deployer, 10_000_000 ether);
    }

    function _approveTokens(
        TestnetScenarioMockERC20 tokenA,
        TestnetScenarioMockERC20 tokenB,
        TestnetContracts memory contracts_
    ) private {
        tokenA.approve(address(contracts_.permit2), type(uint256).max);
        tokenB.approve(address(contracts_.permit2), type(uint256).max);
        tokenA.approve(address(contracts_.swapRouter), type(uint256).max);
        tokenB.approve(address(contracts_.swapRouter), type(uint256).max);

        contracts_.permit2
            .approve(address(tokenA), address(contracts_.positionManager), type(uint160).max, type(uint48).max);
        contracts_.permit2
            .approve(address(tokenB), address(contracts_.positionManager), type(uint160).max, type(uint48).max);
        contracts_.permit2
            .approve(address(tokenA), address(contracts_.poolManager), type(uint160).max, type(uint48).max);
        contracts_.permit2
            .approve(address(tokenB), address(contracts_.poolManager), type(uint160).max, type(uint48).max);
    }

    function _poolKey(TestnetScenarioMockERC20 tokenA, TestnetScenarioMockERC20 tokenB, DirectionalToxicityShield hook)
        private
        pure
        returns (PoolKey memory)
    {
        Currency currencyA = Currency.wrap(address(tokenA));
        Currency currencyB = Currency.wrap(address(tokenB));
        (Currency currency0, Currency currency1) =
            currencyA < currencyB ? (currencyA, currencyB) : (currencyB, currencyA);

        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
    }

    function _initializePoolAndAddLiquidity(IPositionManager positionManager, PoolKey memory poolKey, address recipient)
        private
    {
        positionManager.initializePool(poolKey, SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);
        uint128 liquidity = 100 ether;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidity
        );

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP), uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(
            poolKey, tickLower, tickUpper, liquidity, amount0Expected + 1, amount1Expected + 1, recipient, bytes("")
        );
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        params[2] = abi.encode(poolKey.currency0, recipient);
        params[3] = abi.encode(poolKey.currency1, recipient);

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
    }

    function _swapExactIn(IUniswapV4Router04 swapRouter, PoolKey memory poolKey, bool zeroForOne, address receiver)
        private
    {
        swapRouter.swapExactTokensForTokens({
            amountIn: 1 ether,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: bytes(""),
            receiver: receiver,
            deadline: block.timestamp + 1 hours
        });
    }
}

contract TestnetScenarioMockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
