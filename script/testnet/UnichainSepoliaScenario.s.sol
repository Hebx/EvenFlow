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

contract UnichainSepoliaScenario is Script {
    using PoolIdLibrary for PoolKey;

    uint256 private constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;
    uint160 private constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        require(block.chainid == UNICHAIN_SEPOLIA_CHAIN_ID, "Scenario: expected Unichain Sepolia");

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        IPermit2 permit2 = IPermit2(AddressConstants.getPermit2Address());
        IPoolManager poolManager = IPoolManager(AddressConstants.getPoolManagerAddress(block.chainid));
        IPositionManager positionManager = IPositionManager(AddressConstants.getPositionManagerAddress(block.chainid));
        IUniswapV4Router04 swapRouter =
            IUniswapV4Router04(payable(AddressConstants.getV4SwapRouterAddress(block.chainid)));

        vm.startBroadcast(deployerPrivateKey);

        address existingHook = vm.envOr("DTS_HOOK_ADDRESS", address(0));
        DirectionalToxicityShield hook = _deployOrUseHook(poolManager, existingHook);
        (Stage3MockERC20 tokenA, Stage3MockERC20 tokenB) = _deployTokens(deployer);
        _approveTokens(tokenA, tokenB, permit2, positionManager, poolManager, swapRouter);

        PoolKey memory poolKey = _poolKey(tokenA, tokenB, hook);
        PoolId poolId = poolKey.toId();

        _initializePoolAndAddLiquidity(positionManager, poolKey, deployer);
        _swapExactIn(swapRouter, poolKey, false, deployer);
        uint24 firstFee = hook.getDirectionalState(poolId).lastFee;
        _swapExactIn(swapRouter, poolKey, false, deployer);
        DirectionalToxicityShield.DirectionalState memory state = hook.getDirectionalState(poolId);

        vm.stopBroadcast();

        console2.log("network", "unichain-sepolia");
        console2.log("deployer", deployer);
        console2.log("poolManager", address(poolManager));
        console2.log("positionManager", address(positionManager));
        console2.log("swapRouter", address(swapRouter));
        console2.log("hook", address(hook));
        console2.log("token0", Currency.unwrap(poolKey.currency0));
        console2.log("token1", Currency.unwrap(poolKey.currency1));
        console2.logBytes32(PoolId.unwrap(poolId));
        console2.log("firstFee", firstFee);
        console2.log("secondFee", state.lastFee);
        console2.log("pressure", int256(state.pressure));
        console2.log("lastTick", int256(state.lastTick));
        console2.log("regime", uint256(state.regime));
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
        );
        bytes memory constructorArgs = abi.encode(poolManager);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(DirectionalToxicityShield).creationCode, constructorArgs);

        hook = new DirectionalToxicityShield{salt: salt}(poolManager);
        require(address(hook) == hookAddress, "Scenario: hook address mismatch");
    }

    function _deployTokens(address deployer) private returns (Stage3MockERC20 tokenA, Stage3MockERC20 tokenB) {
        tokenA = new Stage3MockERC20("DTS Test Token A", "DTS-A", 18);
        tokenB = new Stage3MockERC20("DTS Test Token B", "DTS-B", 18);
        tokenA.mint(deployer, 10_000_000 ether);
        tokenB.mint(deployer, 10_000_000 ether);
    }

    function _approveTokens(
        Stage3MockERC20 tokenA,
        Stage3MockERC20 tokenB,
        IPermit2 permit2,
        IPositionManager positionManager,
        IPoolManager poolManager,
        IUniswapV4Router04 swapRouter
    ) private {
        tokenA.approve(address(permit2), type(uint256).max);
        tokenB.approve(address(permit2), type(uint256).max);
        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);

        permit2.approve(address(tokenA), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(tokenB), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(tokenA), address(poolManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(tokenB), address(poolManager), type(uint160).max, type(uint48).max);
    }

    function _poolKey(Stage3MockERC20 tokenA, Stage3MockERC20 tokenB, DirectionalToxicityShield hook)
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

contract Stage3MockERC20 {
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
