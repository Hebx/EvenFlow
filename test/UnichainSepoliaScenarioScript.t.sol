// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {BaseSepoliaScenario} from "../script/testnet/BaseSepoliaScenario.s.sol";
import {UnichainSepoliaScenario} from "../script/testnet/UnichainSepoliaScenario.s.sol";

contract UnichainSepoliaScenarioScriptTest is Test {
    function test_scriptExposesRunEntrypoint() public pure {
        assertEq(UnichainSepoliaScenario.run.selector, bytes4(keccak256("run()")));
    }

    function test_baseSepoliaScriptExposesRunEntrypoint() public pure {
        assertEq(BaseSepoliaScenario.run.selector, bytes4(keccak256("run()")));
    }
}
