// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @title JDS AsymmetricFeesHook — faithful reimplementation for comparative testing
/// @notice Reimplements the exact fee logic from github.com/Jds-23/asymmetric-fees-hook/src/TheHook.sol
/// @dev Key difference from our model: uses sqrtPriceX96 delta, not tick delta.
///      Updates once per block. No min/max fee clamp. No decay.
contract JdsAsymmetricFeesComparator is BaseHook {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error MustUseDynamicFee();

    uint24 public constant BASE_FEE = 3000;
    uint256 public constant MULTIPLIER = 7500;
    uint24 public constant MULTIPLIER_DIVISOR = 1_000_000;

    mapping(PoolId => uint256) public poolToLastUpdatedBN;
    mapping(PoolId => uint160) public poolToPrvSqrtPriceX96;
    mapping(PoolId => uint24) public poolToCurrentFeeDelta;
    mapping(PoolId => int8) public poolToCurrentFeeDeltaSign;

    // Track last applied fee for test readback
    mapping(PoolId => uint24) public lastAppliedFee;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal pure override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return BaseHook.beforeInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        if (poolToLastUpdatedBN[poolId] < block.number) {
            poolToLastUpdatedBN[poolId] = block.number;
            _setFee(poolId);
        }

        uint24 fee = BASE_FEE;
        if (params.zeroForOne) {
            if (poolToCurrentFeeDeltaSign[poolId] == -1) {
                fee = fee + poolToCurrentFeeDelta[poolId];
            } else if (poolToCurrentFeeDeltaSign[poolId] == 1) {
                fee = poolToCurrentFeeDelta[poolId] >= fee ? 0 : fee - poolToCurrentFeeDelta[poolId];
            }
        } else {
            if (poolToCurrentFeeDeltaSign[poolId] == 1) {
                fee = fee + poolToCurrentFeeDelta[poolId];
            } else if (poolToCurrentFeeDeltaSign[poolId] == -1) {
                fee = poolToCurrentFeeDelta[poolId] >= fee ? 0 : fee - poolToCurrentFeeDelta[poolId];
            }
        }

        lastAppliedFee[poolId] = fee;
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _setFee(PoolId poolId) internal {
        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        if (currentSqrtPriceX96 == poolToPrvSqrtPriceX96[poolId]) return;

        if (poolToPrvSqrtPriceX96[poolId] == 0) {
            poolToPrvSqrtPriceX96[poolId] = currentSqrtPriceX96;
            poolToCurrentFeeDelta[poolId] = 0;
            return;
        }

        uint160 sqrtPriceDelta;
        if (poolToPrvSqrtPriceX96[poolId] > currentSqrtPriceX96) {
            sqrtPriceDelta = poolToPrvSqrtPriceX96[poolId] - currentSqrtPriceX96;
            poolToCurrentFeeDeltaSign[poolId] = -1;
        } else {
            sqrtPriceDelta = currentSqrtPriceX96 - poolToPrvSqrtPriceX96[poolId];
            poolToCurrentFeeDeltaSign[poolId] = 1;
        }

        uint256 feeToChange = (MULTIPLIER * uint256(sqrtPriceDelta)) / MULTIPLIER_DIVISOR;
        if (feeToChange >= uint256(BASE_FEE)) {
            poolToCurrentFeeDelta[poolId] = BASE_FEE;
        } else {
            poolToCurrentFeeDelta[poolId] = uint24(feeToChange);
        }

        poolToPrvSqrtPriceX96[poolId] = currentSqrtPriceX96;
    }
}

/// @title RegisGraptin Nezlobin Hook — faithful reimplementation
/// @notice Reimplements github.com/RegisGraptin/Uniswap-Nezlobin-Hook/src/NezlobinHook.sol
/// @dev Uses tick delta, direction based on zeroForOne only (not tick sign). MIN_FEE=500, MAX_FEE=50000.
contract RegisNezlobinComparator is BaseHook {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error MustUseDynamicFee();

    uint24 public constant BASE_FEE = 3000;
    uint24 public constant MIN_FEE = 500;
    uint24 public constant MAX_FEE = 50_000;
    uint24 public constant SCALE = 1000;
    uint24 public constant C = 750;

    mapping(PoolId => uint256) public lastBlockTimestamps;
    mapping(PoolId => int24) public lastTicks;
    mapping(PoolId => uint24) public lastAppliedFee;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        PoolId poolId = key.toId();
        lastBlockTimestamps[poolId] = block.timestamp;
        lastTicks[poolId] = tick;
        return BaseHook.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        // Update tick once per timestamp (matches original's block.timestamp check)
        if (lastBlockTimestamps[poolId] < block.timestamp) {
            lastBlockTimestamps[poolId] = block.timestamp;
            (, int24 currentTick,,) = poolManager.getSlot0(poolId);
            lastTicks[poolId] = currentTick;
        }

        uint24 fee = _calculateDynamicFee(poolId, params.zeroForOne);
        lastAppliedFee[poolId] = fee;
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _calculateDynamicFee(PoolId poolId, bool zeroForOne) internal view returns (uint24) {
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        int24 tickDelta = currentTick - lastTicks[poolId];

        if (tickDelta == 0) return BASE_FEE;

        uint24 delta = tickDelta < 0 ? uint24(-tickDelta) : uint24(tickDelta);
        uint256 ddeltaFee = (uint256(delta) * uint256(C)) / uint256(SCALE);
        uint24 deltaFee = uint24(ddeltaFee);

        if (zeroForOne) {
            if (deltaFee > BASE_FEE - MIN_FEE) return MIN_FEE;
            return BASE_FEE - deltaFee;
        } else {
            uint256 premium = uint256(BASE_FEE) + deltaFee;
            return premium > MAX_FEE ? MAX_FEE : uint24(premium);
        }
    }
}

/// @title InfHook Nezlobin — faithful reimplementation
/// @notice Reimplements github.com/emrhncvsgl/InfHook/backend/src/Nezlobin.sol
/// @dev Has the algebraic bug: beta = (750*3000)/(delta*1000) * delta = 2250 always.
///      Uses updateDynamicLPFee (persists). We use OVERRIDE_FEE_FLAG for test compatibility.
contract InfHookNezlobinComparator is BaseHook {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error MustUseDynamicFee();

    uint24 public constant SCALE = 1000;
    uint24 public constant MULTIPLIER = 750;
    uint24 public constant BASE_FEE = 3000;
    uint24 public constant MIN_FEE = 500;

    mapping(PoolId => uint256) public poolToTimeStamp;
    mapping(PoolId => int24) public poolToTick;
    mapping(PoolId => uint24) public lastAppliedFee;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        PoolId poolId = key.toId();
        poolToTimeStamp[poolId] = block.timestamp;
        return BaseHook.beforeInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        uint24 fee = BASE_FEE;

        if (block.timestamp - poolToTimeStamp[poolId] > 1) {
            poolToTimeStamp[poolId] = block.timestamp;
            (, int24 currentTick,,) = poolManager.getSlot0(poolId);
            int24 tickDeltaSigned = currentTick - poolToTick[poolId];
            uint24 tickDelta = tickDeltaSigned >= 0 ? uint24(tickDeltaSigned) : uint24(-tickDeltaSigned);

            if (tickDelta > 0) {
                fee = _calculateDynamicFee(tickDelta, params.zeroForOne);
            }
            poolToTick[poolId] = currentTick;
        }

        lastAppliedFee[poolId] = fee;
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _calculateDynamicFee(uint24 delta, bool zeroForOne) internal pure returns (uint24) {
        // This produces constant beta = 2250 due to algebraic cancellation
        uint24 c = uint24((uint256(MULTIPLIER) * BASE_FEE) / (uint256(delta) * SCALE));
        uint24 beta = c * delta;

        if (!zeroForOne) {
            return BASE_FEE + beta;
        } else {
            if (beta > BASE_FEE) return MIN_FEE;
            return BASE_FEE - beta;
        }
    }
}

/// @title VPIN Dynamic Fee Hook — faithful reimplementation for comparative testing
/// @notice Reimplements github.com/mishoko/uniswap-hooks-capstone-mishoko/src/VPINDynamicFeeHook.sol
/// @dev Two-layer: VPIN bucket toxicity + Nezlobin directional adjustment proportional to fee*|tickDelta|/10000.
contract VpinDynamicFeeComparator is BaseHook {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error MustUseDynamicFee();

    uint256 public constant BUCKET_SIZE = 100e18;
    uint24 public constant BASE_FEE = 3000;
    uint24 public constant MAX_FEE = 10_000;
    uint256 public constant NUM_BUCKETS = 50;
    uint256 public constant WAD = 1e18;

    struct VPINState {
        uint256[50] buyVolumes;
        uint256[50] sellVolumes;
        uint256 currentBucketIdx;
        uint256 currentBucketBuyVol;
        uint256 currentBucketSellVol;
        uint256 currentBucketTotalVol;
        uint256 filledBuckets;
        uint256 lastVPIN;
    }

    mapping(PoolId => VPINState) internal vpinStates;
    mapping(PoolId => int24) public lastTicks;
    mapping(PoolId => uint256) public lastBlockNumbers;
    mapping(PoolId => uint24) public lastAppliedFee;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal pure override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return BaseHook.beforeInitialize.selector;
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        lastTicks[poolId] = tick;
        lastBlockNumbers[poolId] = block.number;
        return BaseHook.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        uint256 vpin = vpinStates[poolId].lastVPIN;
        uint24 vpinFee = BASE_FEE + uint24(uint256(MAX_FEE - BASE_FEE) * vpin / WAD);

        int24 tickDelta = 0;
        if (block.number > lastBlockNumbers[poolId]) {
            (, int24 currentTick,,) = poolManager.getSlot0(poolId);
            tickDelta = currentTick - lastTicks[poolId];
        }

        uint24 fee = _applyDirectionalAdjustment(vpinFee, tickDelta, params.zeroForOne);
        lastAppliedFee[poolId] = fee;
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();

        bool isBuy = !params.zeroForOne;
        int128 inputAmount = params.zeroForOne ? delta.amount0() : delta.amount1();
        uint256 volume = inputAmount < 0 ? uint256(uint128(-inputAmount)) : uint256(uint128(inputAmount));

        _accumulate(poolId, isBuy, volume);

        if (block.number > lastBlockNumbers[poolId]) {
            (, int24 currentTick,,) = poolManager.getSlot0(poolId);
            lastTicks[poolId] = currentTick;
            lastBlockNumbers[poolId] = block.number;
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    function _applyDirectionalAdjustment(uint24 fee, int24 tickDelta, bool zeroForOne) internal pure returns (uint24) {
        if (tickDelta == 0) return fee;

        bool swapAlignedWithMomentum = (tickDelta > 0 && !zeroForOne) || (tickDelta < 0 && zeroForOne);

        uint256 absDelta = tickDelta > 0 ? uint256(int256(tickDelta)) : uint256(int256(-tickDelta));
        uint24 adjustment = uint24((uint256(fee) * absDelta) / 10000);

        uint24 maxAdjustment = fee / 2;
        if (adjustment > maxAdjustment) adjustment = maxAdjustment;

        if (swapAlignedWithMomentum) {
            return fee + adjustment;
        } else {
            return fee > adjustment ? fee - adjustment : 1;
        }
    }

    function _accumulate(PoolId poolId, bool isBuy, uint256 volume) internal {
        VPINState storage state = vpinStates[poolId];
        uint256 remaining = volume;

        while (remaining > 0) {
            uint256 spaceInBucket = BUCKET_SIZE - state.currentBucketTotalVol;

            if (remaining >= spaceInBucket) {
                if (isBuy) {
                    state.currentBucketBuyVol += spaceInBucket;
                } else {
                    state.currentBucketSellVol += spaceInBucket;
                }
                remaining -= spaceInBucket;

                uint256 idx = state.currentBucketIdx;
                state.buyVolumes[idx] = state.currentBucketBuyVol;
                state.sellVolumes[idx] = state.currentBucketSellVol;

                state.currentBucketIdx = (idx + 1) % NUM_BUCKETS;
                if (state.filledBuckets < NUM_BUCKETS) state.filledBuckets++;

                state.currentBucketBuyVol = 0;
                state.currentBucketSellVol = 0;
                state.currentBucketTotalVol = 0;

                state.lastVPIN = _computeVPIN(state);
            } else {
                if (isBuy) {
                    state.currentBucketBuyVol += remaining;
                } else {
                    state.currentBucketSellVol += remaining;
                }
                state.currentBucketTotalVol += remaining;
                remaining = 0;
            }
        }
    }

    function _computeVPIN(VPINState storage state) internal view returns (uint256) {
        uint256 n = state.filledBuckets;
        if (n == 0) return 0;

        uint256 totalImbalance = 0;
        for (uint256 i = 0; i < n; i++) {
            uint256 buyVol = state.buyVolumes[i];
            uint256 sellVol = state.sellVolumes[i];
            totalImbalance += buyVol > sellVol ? buyVol - sellVol : sellVol - buyVol;
        }

        return (totalImbalance * WAD) / (n * BUCKET_SIZE);
    }

    function getVPIN(PoolId poolId) external view returns (uint256) {
        return vpinStates[poolId].lastVPIN;
    }
}
