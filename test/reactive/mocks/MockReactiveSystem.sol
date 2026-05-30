// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";

/// @dev Minimal mock of the Reactive system contract for local tests. Records
/// subscriptions and the last requested callback so tests can assert what the
/// controller would send to the destination chain. Does not bridge anything.
contract MockReactiveSystem is ISystemContract {
    struct Subscription {
        uint256 chainId;
        address contractAddress;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
    }

    Subscription[] public subscriptions;

    struct Callback {
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    Callback public lastCallback;
    uint256 public callbackCount;

    function subscriptionCount() external view returns (uint256) {
        return subscriptions.length;
    }

    function getSubscription(uint256 i) external view returns (Subscription memory) {
        return subscriptions[i];
    }

    // ── ISubscriptionService ──
    function subscribe(uint256 chainId_, address contract_, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external {
        subscriptions.push(Subscription(chainId_, contract_, t0, t1, t2, t3));
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    // ── IPayable ──
    receive() external payable {}

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    // ── ISystemContract callbacks ──
    function requestCallback(CallbackVersion, bytes memory config_) external {
        CallbackConfiguration_V_1_0 memory c = abi.decode(config_, (CallbackConfiguration_V_1_0));
        _record(c);
    }

    function requestCallbackV_1_0(CallbackConfiguration_V_1_0 memory config_) external {
        _record(config_);
    }

    function _record(CallbackConfiguration_V_1_0 memory c) internal {
        lastCallback = Callback(c.chainId, c.recipient, c.gasLimit, c.payload);
        callbackCount++;
    }
}
