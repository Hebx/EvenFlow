// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {ShieldReactiveController} from "../../src/reactive/ShieldReactiveController.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {MockReactiveSystem} from "./mocks/MockReactiveSystem.sol";

/// @dev Unit tests for the Lasna-side reactive controller. The Reactive system
/// contract is a hardcoded constant (0x8888...8888); we etch a mock there so the
/// controller's constructor subscriptions and react()-driven callback requests
/// can be observed locally without a live Reactive Network.
contract ShieldReactiveControllerTest is Test {
    uint256 private constant RISK_REGIME_CHANGED_TOPIC0 =
        0xb8a947857cc396ba992936587c4bfebf37908e930241b80287b6f5a612963ed8;
    uint256 private constant CRON100_TOPIC0 = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;

    address private constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address private constant CRON_SYSTEM = 0x0000000000000000000000000000000000fffFfF;

    uint256 private constant ORIGIN_CHAIN = 84532; // Base Sepolia
    uint256 private constant DEST_CHAIN = 84532;
    address private constant HOOK = address(0x538c73F7731d0D4bCEa6ee264955F66c5bd830c4);
    address private constant EXECUTOR = address(0xE9EC);

    MockReactiveSystem system;
    ShieldReactiveController controller;
    PoolId targetPool;

    function setUp() public {
        // Place the mock at the hardcoded SYSTEM address.
        MockReactiveSystem impl = new MockReactiveSystem();
        vm.etch(SYSTEM_ADDR, address(impl).code);
        system = MockReactiveSystem(payable(SYSTEM_ADDR));

        targetPool = PoolId.wrap(bytes32(uint256(0xABCD)));
        controller = new ShieldReactiveController(ORIGIN_CHAIN, HOOK, DEST_CHAIN, EXECUTOR, targetPool);
    }

    function test_constructor_subscribesToRegimeAndCron() public view {
        assertEq(system.subscriptionCount(), 2, "two subscriptions");

        MockReactiveSystem.Subscription memory s0 = system.getSubscription(0);
        assertEq(s0.chainId, ORIGIN_CHAIN);
        assertEq(s0.contractAddress, HOOK);
        assertEq(s0.topic0, RISK_REGIME_CHANGED_TOPIC0);

        MockReactiveSystem.Subscription memory s1 = system.getSubscription(1);
        assertEq(s1.contractAddress, CRON_SYSTEM);
        assertEq(s1.topic0, CRON100_TOPIC0);
    }

    function test_react_quietRegimeRequestsDripCallback() public {
        bytes32 poolId = bytes32(uint256(0xBEEF));
        // RiskRegimeChanged(poolId indexed, oldRegime=2, newRegime=0) -> quiet.
        IReactive.LogRecord memory log = _regimeLog(poolId, 2, 0);

        vm.prank(SYSTEM_ADDR);
        controller.react(log);

        assertEq(system.callbackCount(), 1, "one callback requested");
        (uint256 chainId, address recipient, uint64 gasLimit, bytes memory payload) = system.lastCallback();
        assertEq(chainId, DEST_CHAIN);
        assertEq(recipient, EXECUTOR);
        assertGt(gasLimit, 0);

        // payload = onQuietDrip(address(0) placeholder, poolId)
        bytes memory expected = abi.encodeWithSignature("onQuietDrip(address,bytes32)", address(0), poolId);
        assertEq(keccak256(payload), keccak256(expected), "callback payload addresses the pool");
    }

    function test_react_nonQuiteRegimeDoesNotRequestCallback() public {
        bytes32 poolId = bytes32(uint256(0xBEEF));
        // newRegime = 2 (still toxic): no drip.
        IReactive.LogRecord memory log = _regimeLog(poolId, 1, 2);

        vm.prank(SYSTEM_ADDR);
        controller.react(log);

        assertEq(system.callbackCount(), 0, "no callback when not quiet");
    }

    function test_react_cronSweepsTargetPool() public {
        IReactive.LogRecord memory log;
        log.topic0 = CRON100_TOPIC0;
        log.contractAddress = CRON_SYSTEM;

        vm.prank(SYSTEM_ADDR);
        controller.react(log);

        assertEq(system.callbackCount(), 1, "cron triggers a sweep callback");
        (,,, bytes memory payload) = system.lastCallback();
        bytes memory expected =
            abi.encodeWithSignature("onQuietDrip(address,bytes32)", address(0), PoolId.unwrap(targetPool));
        assertEq(keccak256(payload), keccak256(expected), "cron sweep addresses the target pool");
    }

    function test_react_revertsForNonSystemCaller() public {
        IReactive.LogRecord memory log = _regimeLog(bytes32(uint256(1)), 2, 0);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        controller.react(log);
    }

    function _regimeLog(bytes32 poolId, uint256 oldRegime, uint256 newRegime)
        private
        pure
        returns (IReactive.LogRecord memory log)
    {
        log.chainId = ORIGIN_CHAIN;
        log.contractAddress = HOOK;
        log.topic0 = RISK_REGIME_CHANGED_TOPIC0;
        log.topic1 = uint256(poolId);
        log.data = abi.encode(oldRegime, newRegime);
    }
}
