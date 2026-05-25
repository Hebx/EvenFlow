// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TestnetDirectionalScenario} from "./TestnetDirectionalScenario.sol";

contract UnichainSepoliaScenario is TestnetDirectionalScenario {
    uint256 private constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;

    function run() external {
        _runScenario(UNICHAIN_SEPOLIA_CHAIN_ID, "unichain-sepolia");
    }
}
