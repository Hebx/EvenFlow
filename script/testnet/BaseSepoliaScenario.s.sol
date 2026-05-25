// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TestnetDirectionalScenario} from "./TestnetDirectionalScenario.sol";

contract BaseSepoliaScenario is TestnetDirectionalScenario {
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84532;

    function run() external {
        _runScenario(BASE_SEPOLIA_CHAIN_ID, "base-sepolia");
    }
}
