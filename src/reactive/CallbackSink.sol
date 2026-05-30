// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractCallback} from "reactive-lib-classic/abstract-base/AbstractCallback.sol";

/// @title CallbackSink
/// @notice Dead-simple no-auth destination for isolating legacy->Base Sepolia
/// callback delivery. Extends classic AbstractCallback so the callback proxy is
/// the authorized vendor (constructor arg = proxy), but onPing performs NO auth
/// checks at all: any delivered callback increments the counter and emits an
/// event the sink owns (so detection does not depend on the proxy emitting logs).
///
/// If callCount/Pinged ever moves, the Reactive Signer IS delivering legacy
/// callbacks to Base Sepolia. If it never moves while a legacy reactive contract
/// emits Callback(...) targeting this sink every cron tick, delivery is down.
contract CallbackSink is AbstractCallback {
    uint256 public callCount;
    address public lastSender;
    uint256 public lastBlock;

    event Pinged(address indexed sender, uint256 count, uint256 blk);

    constructor(address callbackProxy_) AbstractCallback(callbackProxy_) payable {}

    /// @notice Callback target. First arg is the proxy-injected reactive address.
    /// No authorization on purpose: this is a delivery-path litmus test.
    function onPing(address sender) external {
        callCount++;
        lastSender = sender;
        lastBlock = block.number;
        emit Pinged(sender, callCount, block.number);
    }

    receive() external payable override {}
}
