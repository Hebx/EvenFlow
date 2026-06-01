// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {ShieldReactiveController} from "../../src/reactive/ShieldReactiveController.sol";
import {IReactive} from "reactive-lib-classic/interfaces/IReactive.sol";
import {MockReactiveSystem} from "./mocks/MockReactiveSystem.sol";

/// @dev Unit tests for the legacy (classic reactive-lib) ShieldReactiveController.
///
/// The classic system contract is at `0x0000000000000000000000000000000000fffFfF`.
/// `detectVm()` checks for code at that address:
///  - code present  → vm = false (Reactive Network context, subscriptions work)
///  - code absent   → vm = true  (ReactVM context, react() works)
///
/// We test subscriptions with the mock etched, and react() without it.
contract ShieldReactiveControllerTest is Test {
    uint256 private constant RISK_REGIME_CHANGED_TOPIC0 =
        0xb8a947857cc396ba992936587c4bfebf37908e930241b80287b6f5a612963ed8;

    // Representative CRON values (network params supplied at deploy time).
    uint256 private constant CRON_TOPIC0 = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;

    address private constant SYSTEM_ADDR = 0x0000000000000000000000000000000000fffFfF;
    address private constant CRON_SYSTEM = 0x0000000000000000000000000000000000fffFfF;

    uint256 private constant ORIGIN_CHAIN = 84532; // Base Sepolia
    uint256 private constant DEST_CHAIN = 84532;
    address private constant HOOK = address(0x538c73F7731d0D4bCEa6ee264955F66c5bd830c4);
    address private constant EXECUTOR = address(0xE9EC);

    /// @dev topic0 of the inherited Callback(uint256 indexed, address indexed, uint64 indexed, bytes)
    bytes32 private constant CALLBACK_EVENT_TOPIC0 = keccak256("Callback(uint256,address,uint64,bytes)");

    MockReactiveSystem system;
    PoolId targetPool;

    function setUp() public {
        // Place the mock at the hardcoded system address so constructor subscriptions work.
        MockReactiveSystem impl = new MockReactiveSystem();
        vm.etch(SYSTEM_ADDR, address(impl).code);
        system = MockReactiveSystem(payable(SYSTEM_ADDR));
        targetPool = PoolId.wrap(bytes32(uint256(0xABCD)));
    }

    /// @dev Deploy the controller WITH the system contract present (vm=false,
    /// Reactive Network context). Subscriptions are created in the constructor.
    function _deployRnController() private returns (ShieldReactiveController) {
        return
            new ShieldReactiveController(ORIGIN_CHAIN, HOOK, DEST_CHAIN, EXECUTOR, targetPool, CRON_SYSTEM, CRON_TOPIC0);
    }

    /// @dev Deploy the controller WITHOUT the system contract present (vm=true,
    /// ReactVM context). react() is callable. No subscriptions are created.
    function _deployVmController() private returns (ShieldReactiveController) {
        // Temporarily remove code at the system address so detectVm() sets vm=true.
        vm.etch(SYSTEM_ADDR, "");
        ShieldReactiveController c = new ShieldReactiveController(
            ORIGIN_CHAIN, HOOK, DEST_CHAIN, EXECUTOR, targetPool, CRON_SYSTEM, CRON_TOPIC0
        );
        // Restore the mock for any subsequent calls.
        MockReactiveSystem impl = new MockReactiveSystem();
        vm.etch(SYSTEM_ADDR, address(impl).code);
        return c;
    }

    function test_constructor_subscribesToRegimeAndCron() public {
        _deployRnController();

        assertEq(system.subscriptionCount(), 2, "two subscriptions");

        MockReactiveSystem.Subscription memory s0 = system.getSubscription(0);
        assertEq(s0.chainId, ORIGIN_CHAIN);
        assertEq(s0.contractAddress, HOOK);
        assertEq(s0.topic0, RISK_REGIME_CHANGED_TOPIC0);

        MockReactiveSystem.Subscription memory s1 = system.getSubscription(1);
        assertEq(s1.contractAddress, CRON_SYSTEM);
        assertEq(s1.topic0, CRON_TOPIC0);
    }

    function test_react_quietRegimeEmitsCallback() public {
        ShieldReactiveController controller = _deployVmController();

        bytes32 poolId = bytes32(uint256(0xBEEF));
        IReactive.LogRecord memory log = _regimeLog(poolId, 2, 0);

        vm.recordLogs();
        controller.react(log);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bool found, uint256 chainId, address recipient, bytes memory payload) = _findCallback(logs);
        assertTrue(found, "Callback event emitted");
        assertEq(chainId, DEST_CHAIN);
        assertEq(recipient, EXECUTOR);

        bytes memory expected = abi.encodeWithSignature("onQuietDrip(address,bytes32)", address(0), poolId);
        assertEq(keccak256(payload), keccak256(expected), "callback payload addresses the pool");
    }

    function test_react_nonQuietRegimeDoesNotEmitCallback() public {
        ShieldReactiveController controller = _deployVmController();

        bytes32 poolId = bytes32(uint256(0xBEEF));
        IReactive.LogRecord memory log = _regimeLog(poolId, 1, 2);

        vm.recordLogs();
        controller.react(log);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bool found,,,) = _findCallback(logs);
        assertFalse(found, "no callback when not quiet");
    }

    function test_react_cronSweepsTargetPool() public {
        ShieldReactiveController controller = _deployVmController();

        IReactive.LogRecord memory log;
        log.topic_0 = CRON_TOPIC0;
        log._contract = CRON_SYSTEM;

        vm.recordLogs();
        controller.react(log);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bool found,,, bytes memory payload) = _findCallback(logs);
        assertTrue(found, "cron triggers a sweep callback");

        bytes memory expected =
            abi.encodeWithSignature("onQuietDrip(address,bytes32)", address(0), PoolId.unwrap(targetPool));
        assertEq(keccak256(payload), keccak256(expected), "cron sweep addresses the target pool");
    }

    function test_react_revertsInRnContext() public {
        // When deployed on the Reactive Network (system contract present → vm == false),
        // react() should revert with "VM only".
        ShieldReactiveController rnController = _deployRnController();

        IReactive.LogRecord memory log = _regimeLog(bytes32(uint256(1)), 2, 0);
        vm.expectRevert("VM only");
        rnController.react(log);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────────

    function _regimeLog(bytes32 poolId, uint256 oldRegime, uint256 newRegime)
        private
        pure
        returns (IReactive.LogRecord memory log)
    {
        log.chain_id = ORIGIN_CHAIN;
        log._contract = HOOK;
        log.topic_0 = RISK_REGIME_CHANGED_TOPIC0;
        log.topic_1 = uint256(poolId);
        log.data = abi.encode(oldRegime, newRegime);
    }

    /// @dev Scan recorded logs for the Callback event and decode it.
    function _findCallback(Vm.Log[] memory logs)
        private
        pure
        returns (bool found, uint256 chainId, address recipient, bytes memory payload)
    {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == CALLBACK_EVENT_TOPIC0) {
                chainId = uint256(logs[i].topics[1]);
                recipient = address(uint160(uint256(logs[i].topics[2])));
                // gas_limit is topics[3] (indexed uint64), payload is in data
                payload = abi.decode(logs[i].data, (bytes));
                found = true;
                break;
            }
        }
    }
}
