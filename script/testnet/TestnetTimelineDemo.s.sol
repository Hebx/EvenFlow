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
import {TestnetScenarioMockERC20} from "./TestnetDirectionalScenario.sol";

/// @title Live Testnet Fee-Timeline Demo (two-phase)
/// @notice Broadcasts a multi-phase swap journey against an already-deployed Shield on a
///         live testnet (canonical v4 PoolManager) and captures a per-swap fee timeline.
///         Every entry corresponds to an explorer-verifiable transaction, not a fork.
///
/// @dev Why two phases. forge `--broadcast` simulates the entire script first, then
///      broadcasts. Putting an in-script `vm.sleep` for the decay window therefore stalls
///      simulation and still lands every swap in one simulated block. So the build phase
///      broadcasts setup + base/toxic/counter swaps now, the operator waits real wall-clock
///      time (> 5 min decayWindow), then the quiet phase broadcasts the final swap against
///      the same already-deployed pool, reading on-chain state for the timeline.
///
///      Required env:
///        DEPLOYER_PRIVATE_KEY  - funded EOA for the target testnet
///        DTS_HOOK_ADDRESS      - the already-deployed Shield hook
///        DTS_TIMELINE_NETWORK  - human-readable label, e.g. "base-sepolia"
///        DTS_PHASE             - "build" or "quiet"
///      Phase "quiet" additionally requires:
///        DTS_TIMELINE_TOKEN0   - token0 address emitted by the build phase log
///        DTS_TIMELINE_TOKEN1   - token1 address emitted by the build phase log
contract TestnetTimelineDemo is Script {
    using PoolIdLibrary for PoolKey;

    uint160 private constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 private constant SHIELD_BASE_FEE = 3_000;

    struct PhasePoint {
        string phase;
        bool zeroForOne;
        uint24 fee;
        int56 pressure;
        int24 lastTick;
        uint8 regime;
        uint256 blockNumber;
    }

    struct LiveContracts {
        IPermit2 permit2;
        IPoolManager poolManager;
        IPositionManager positionManager;
        IUniswapV4Router04 swapRouter;
    }

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address hookAddr = vm.envAddress("DTS_HOOK_ADDRESS");
        string memory network = vm.envString("DTS_TIMELINE_NETWORK");
        string memory phase = vm.envString("DTS_PHASE");

        require(hookAddr.code.length > 0, "TimelineDemo: hook has no code on this chain");
        DirectionalToxicityShield hook = DirectionalToxicityShield(hookAddr);
        LiveContracts memory c = _liveContracts();

        if (_eq(phase, "build")) {
            _runBuildPhase(c, hook, deployer, deployerPk, network);
        } else if (_eq(phase, "quiet")) {
            _runQuietPhase(c, hook, deployer, deployerPk, network);
        } else {
            revert("TimelineDemo: DTS_PHASE must be 'build' or 'quiet'");
        }
    }

    // ==================== BUILD PHASE ====================

    function _runBuildPhase(
        LiveContracts memory c,
        DirectionalToxicityShield hook,
        address deployer,
        uint256 deployerPk,
        string memory network
    ) internal {
        vm.startBroadcast(deployerPk);
        TestnetScenarioMockERC20 tokenA = new TestnetScenarioMockERC20("DTS Timeline A", "DTSL-A", 18);
        TestnetScenarioMockERC20 tokenB = new TestnetScenarioMockERC20("DTS Timeline B", "DTSL-B", 18);
        tokenA.mint(deployer, 10_000_000 ether);
        tokenB.mint(deployer, 10_000_000 ether);
        _approveTokens(tokenA, tokenB, c);

        PoolKey memory key = _poolKey(tokenA, tokenB, hook);
        bytes32 poolId = PoolId.unwrap(key.toId());

        _initializePoolAndAddLiquidity(c.positionManager, key, deployer);

        PhasePoint[] memory points = new PhasePoint[](7);
        uint256 i;
        i = _swapAndRecord(c, hook, key, deployer, points, i, "base", false);
        i = _swapAndRecord(c, hook, key, deployer, points, i, "toxic", false);
        i = _swapAndRecord(c, hook, key, deployer, points, i, "toxic", false);
        i = _swapAndRecord(c, hook, key, deployer, points, i, "toxic", false);
        i = _swapAndRecord(c, hook, key, deployer, points, i, "toxic", false);
        i = _swapAndRecord(c, hook, key, deployer, points, i, "counter", true);
        i = _swapAndRecord(c, hook, key, deployer, points, i, "counter", true);
        vm.stopBroadcast();

        require(i == points.length, "TimelineDemo: build phase count mismatch");
        _logArtifact(network, "build", deployer, address(hook), address(c.poolManager), poolId, points);
        console2.log("");
        console2.log("=== handoff to quiet phase ===");
        console2.log("DTS_TIMELINE_TOKEN0=", Currency.unwrap(key.currency0));
        console2.log("DTS_TIMELINE_TOKEN1=", Currency.unwrap(key.currency1));
        console2.log("Wait > 5 minutes (decayWindow) before running DTS_PHASE=quiet.");
    }

    // ==================== QUIET PHASE ====================

    function _runQuietPhase(
        LiveContracts memory c,
        DirectionalToxicityShield hook,
        address deployer,
        uint256 deployerPk,
        string memory network
    ) internal {
        address t0 = vm.envAddress("DTS_TIMELINE_TOKEN0");
        address t1 = vm.envAddress("DTS_TIMELINE_TOKEN1");
        require(t0 != address(0) && t1 != address(0), "TimelineDemo: missing token env");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        bytes32 poolId = PoolId.unwrap(key.toId());

        // On-chain pre-quiet read: shows the state the next swap will price against.
        DirectionalToxicityShield.DirectionalState memory pre = hook.getDirectionalState(key.toId());
        console2.log("# pre-quiet on-chain state");
        console2.log("  fee:     ", uint256(pre.lastFee));
        console2.log("  pressure:", int256(pre.pressure));

        vm.startBroadcast(deployerPk);
        PhasePoint[] memory points = new PhasePoint[](1);
        _swapAndRecord(c, hook, key, deployer, points, 0, "quiet", false);
        vm.stopBroadcast();

        _logArtifact(network, "quiet", deployer, address(hook), address(c.poolManager), poolId, points);
    }

    // ==================== HELPERS ====================

    function _swapAndRecord(
        LiveContracts memory c,
        DirectionalToxicityShield hook,
        PoolKey memory key,
        address receiver,
        PhasePoint[] memory points,
        uint256 i,
        string memory phase,
        bool zeroForOne
    ) internal returns (uint256) {
        c.swapRouter
            .swapExactTokensForTokens({
                amountIn: 1 ether,
                amountOutMin: 0,
                zeroForOne: zeroForOne,
                poolKey: key,
                hookData: bytes(""),
                receiver: receiver,
                deadline: block.timestamp + 1 hours
            });

        DirectionalToxicityShield.DirectionalState memory st = hook.getDirectionalState(key.toId());
        points[i] = PhasePoint({
            phase: phase,
            zeroForOne: zeroForOne,
            fee: st.lastFee,
            pressure: st.pressure,
            lastTick: st.lastTick,
            regime: uint8(st.regime),
            blockNumber: block.number
        });
        return i + 1;
    }

    function _logArtifact(
        string memory network,
        string memory phase,
        address deployer,
        address hook,
        address poolManager,
        bytes32 poolId,
        PhasePoint[] memory points
    ) internal pure {
        console2.log("# Live Testnet Fee Timeline");
        console2.log("network: ", network);
        console2.log("phase:   ", phase);
        console2.log("deployer:", deployer);
        console2.log("hook:    ", hook);
        console2.log("poolManager (canonical):", poolManager);
        console2.logBytes32(poolId);
        console2.log("");
        console2.log("phase | swap | direction | fee(bps) | vs base | pressure | block");
        console2.log("------|------|-----------|----------|---------|----------|------");
        for (uint256 j = 0; j < points.length; j++) {
            PhasePoint memory p = points[j];
            string memory dir = p.zeroForOne ? "0->1" : "1->0";
            string memory vsBase = p.fee > SHIELD_BASE_FEE ? "above" : (p.fee < SHIELD_BASE_FEE ? "below" : "base");
            console2.log(
                string.concat(
                    p.phase, " | ", vm.toString(j + 1), " | ", dir, " | ", vm.toString(uint256(p.fee)), " | ", vsBase
                )
            );
            console2.log("    pressure:", int256(p.pressure));
            console2.log("    block:   ", p.blockNumber);
        }
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _liveContracts() private view returns (LiveContracts memory) {
        return LiveContracts({
            permit2: IPermit2(AddressConstants.getPermit2Address()),
            poolManager: IPoolManager(AddressConstants.getPoolManagerAddress(block.chainid)),
            positionManager: IPositionManager(AddressConstants.getPositionManagerAddress(block.chainid)),
            swapRouter: IUniswapV4Router04(payable(AddressConstants.getV4SwapRouterAddress(block.chainid)))
        });
    }

    function _approveTokens(TestnetScenarioMockERC20 tokenA, TestnetScenarioMockERC20 tokenB, LiveContracts memory c)
        private
    {
        tokenA.approve(address(c.permit2), type(uint256).max);
        tokenB.approve(address(c.permit2), type(uint256).max);
        tokenA.approve(address(c.swapRouter), type(uint256).max);
        tokenB.approve(address(c.swapRouter), type(uint256).max);

        c.permit2.approve(address(tokenA), address(c.positionManager), type(uint160).max, type(uint48).max);
        c.permit2.approve(address(tokenB), address(c.positionManager), type(uint160).max, type(uint48).max);
        c.permit2.approve(address(tokenA), address(c.poolManager), type(uint160).max, type(uint48).max);
        c.permit2.approve(address(tokenB), address(c.poolManager), type(uint160).max, type(uint48).max);
    }

    function _poolKey(TestnetScenarioMockERC20 tokenA, TestnetScenarioMockERC20 tokenB, DirectionalToxicityShield hook)
        private
        pure
        returns (PoolKey memory)
    {
        Currency cA = Currency.wrap(address(tokenA));
        Currency cB = Currency.wrap(address(tokenB));
        (Currency c0, Currency c1) = cA < cB ? (cA, cB) : (cB, cA);
        return PoolKey({
            currency0: c0, currency1: c1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 60, hooks: IHooks(hook)
        });
    }

    function _initializePoolAndAddLiquidity(IPositionManager pm, PoolKey memory key, address recipient) private {
        pm.initializePool(key, SQRT_PRICE_1_1);

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
