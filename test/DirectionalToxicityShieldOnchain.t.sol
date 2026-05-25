// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {DirectionalToxicityShieldOnchainGate} from "./utils/DirectionalToxicityShieldOnchainGate.sol";

contract DirectionalToxicityShieldOnchainTest is Test {
    DirectionalToxicityShieldOnchainGate private gate;

    function setUp() public {
        gate = new DirectionalToxicityShieldOnchainGate();
        gate.setUp();
    }

    function test_stage1LocalFreshV4RunsDirectionalScenario() public {
        if (block.chainid != 31337) vm.skip(true);

        (uint24 firstFee, uint24 secondFee, int56 pressure) = gate.runDirectionalScenario();

        assertEq(firstFee, 3000);
        assertEq(secondFee, 3500);
        assertGt(pressure, 0);
    }

    function test_stage2ForkUsesCanonicalV4Deployments() public {
        if (block.chainid == 31337) vm.skip(true);

        gate.assertCanonicalV4Deployments();
    }

    function test_stage2ForkRunsDirectionalScenarioAgainstCanonicalPoolManager() public {
        if (block.chainid == 31337) vm.skip(true);

        (uint24 firstFee, uint24 secondFee, int56 pressure) = gate.runDirectionalScenario();

        assertEq(firstFee, 3000);
        assertEq(secondFee, 3500);
        assertGt(pressure, 0);
    }
}
