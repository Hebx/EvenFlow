// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {IDirectionalToxicityShield} from "../../src/reactive/IDirectionalToxicityShield.sol";

interface IShieldView {
    struct SmoothingReserve {
        uint128 reserve0;
        uint128 reserve1;
        uint48 lastDripBlock;
    }

    function getSmoothingReserve(PoolId poolId) external view returns (SmoothingReserve memory);
    function getEffectiveRegime(PoolId poolId) external view returns (uint8);
    function getCurrentRegime(PoolId poolId) external view returns (uint8);
}

/// @notice Live Base Sepolia: drive toxic-aligned swaps on the deployed Reactive
/// demo pool to BUILD a smoothing reserve, then leave it stranded (no further
/// swaps) so the autonomous Lasna CRON relay can release it.
///
/// Env:
///  - PRIVATE_KEY  deployer/owner (holds the mock tokens, approved via permit2)
///
/// Run:
///   forge script script/reactive/BuildReserveBaseSepolia.s.sol \
///     --rpc-url "$RPC" --broadcast --slow
contract BuildReserveBaseSepolia is Script {
    using PoolIdLibrary for PoolKey;

    uint256 private constant BASE_SEPOLIA = 84532;

    address private constant SHIELD = 0xf9664050d816d0cAD201B318A30E9D4C4eA270c4;
    address private constant ROUTER = 0x71cD4Ea054F9Cb3D3BF6251A00673303411A7DD9;
    address private constant TOKEN0 = 0x14eCdfD4a7dbf9E79f6085d13D96F421456FB2a4;
    address private constant TOKEN1 = 0x59A6543ee51f0E6d3D9CDe7D30112b315b76beD3;

    function run() external {
        require(block.chainid == BASE_SEPOLIA, "wrong chain: expected Base Sepolia 84532");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(TOKEN0),
            currency1: Currency.wrap(TOKEN1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(SHIELD)
        });
        PoolId poolId = key.toId();

        IShieldView shield = IShieldView(SHIELD);
        IUniswapV4Router04 router = IUniswapV4Router04(payable(ROUTER));

        IShieldView.SmoothingReserve memory before = shield.getSmoothingReserve(poolId);
        console2.log("reserve0 before:", before.reserve0);
        console2.log("reserve1 before:", before.reserve1);
        console2.log("regime before  :", shield.getCurrentRegime(poolId));

        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        // Toxic-aligned: repeated same-direction swaps build directional pressure
        // -> fee climbs above baseFee -> premium captured into the reserve.
        // zeroForOne=true: sell token0 for token1 (push price one way).
        for (uint256 i = 0; i < 6; i++) {
            router.swapExactTokensForTokens({
                amountIn: 5e18,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: key,
                hookData: "",
                receiver: msg.sender,
                deadline: block.timestamp + 600
            });
        }

        vm.stopBroadcast();

        IShieldView.SmoothingReserve memory afterR = shield.getSmoothingReserve(poolId);
        console2.log("reserve0 after :", afterR.reserve0);
        console2.log("reserve1 after :", afterR.reserve1);
        console2.log("regime after   :", shield.getCurrentRegime(poolId));
        console2.log("--- now leave the pool idle; CRON relay should release the reserve with no swap ---");
    }
}
