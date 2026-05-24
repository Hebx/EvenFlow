// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DirectionalToxicityShieldSimulation} from "../script/DirectionalToxicityShieldSimulation.s.sol";

contract DirectionalToxicityShieldSimulationTest is Test {
    DirectionalToxicityShieldSimulation private simulation;

    function setUp() public {
        simulation = new DirectionalToxicityShieldSimulation();
    }

    function testOneDirectionScenarioComparesNezlobinModels() public view {
        DirectionalToxicityShieldSimulation.ScenarioResult memory result = simulation.simulateOneDirection();

        assertEq(result.staticFees, 12_000e18);
        assertEq(result.asymmetricPreviousMoveFees, 12_045e18);
        assertEq(result.regisNezlobinFees, 12_045e18);
        assertEq(result.infHookNezlobinFees, 18_720e18);
        assertEq(result.jaseempkThresholdFees, 5_200e18);
        assertEq(result.shieldFees, 13_200e18);
        assertEq(result.maxAsymmetricPreviousMoveFee, 3015);
        assertEq(result.maxRegisNezlobinFee, 3015);
        assertEq(result.maxInfHookNezlobinFee, 5240);
        assertEq(result.maxJaseempkThresholdFee, 1600);
    }

    function testAlternatingScenarioShowsModelDifferences() public view {
        DirectionalToxicityShieldSimulation.ScenarioResult memory result = simulation.simulateAlternating();

        assertEq(result.staticFees, 12_000e18);
        assertEq(result.asymmetricPreviousMoveFees, 11_955e18);
        assertEq(result.regisNezlobinFees, 11_985e18);
        assertEq(result.infHookNezlobinFees, 9_760e18);
        assertEq(result.jaseempkThresholdFees, 2_800e18);
        assertEq(result.shieldFees, 11_600e18);
    }

    function testQuietScenarioKeepsNonDecayingComparatorsVisible() public view {
        DirectionalToxicityShieldSimulation.ScenarioResult memory result = simulation.simulateQuietReset();

        assertEq(result.staticFees, 12_000e18);
        assertEq(result.asymmetricPreviousMoveFees, 12_054e18);
        assertEq(result.regisNezlobinFees, 12_036e18);
        assertEq(result.infHookNezlobinFees, 18_750e18);
        assertEq(result.jaseempkThresholdFees, 5_250e18);
        assertEq(result.shieldFees, 12_750e18);
    }
}
