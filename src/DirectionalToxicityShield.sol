// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";

contract DirectionalToxicityShield is BaseHook {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using SafeCast for uint256;
    using TransientSlot for *;
    using SlotDerivation for *;

    error NotDynamicFee();
    error InvalidFeeBounds();
    error InvalidStepSize();
    error InvalidPressureScale();
    error InvalidDecayFactor();
    error InvalidDecayWindow();
    error InvalidMajorMoveThreshold();
    error NotPoolConfigurer();
    error InvalidDripInterval();
    error InvalidDripBps();
    error NotReactiveExecutor();
    error InvalidPolicyMode();

    struct FeePolicy {
        uint24 baseFee;
        uint24 minFee;
        uint24 maxFee;
        uint24 maxFeeStep;
        uint32 pressureScale;
        int24 maxPressure;
        uint32 decayFactor;
        uint32 filterWindow;
        uint32 decayWindow;
        uint128 liquidityFloor;
        int24 majorMoveThreshold;
    }

    struct DirectionalState {
        int24 referenceTick;
        int24 lastTick;
        int56 pressure;
        uint40 lastUpdateTime;
        uint24 lastFee;
        uint8 regime;
        uint40 lastPressureBlock;
    }

    /// @dev Per-pool, opt-in yield-smoothing knobs. Disabled by default so the
    /// base product (pure directional dynamic fee) is unchanged unless the pool
    /// configurer explicitly enables smoothing via {configureSmoothing}.
    struct SmoothingConfig {
        bool enabled;
        uint32 dripBlockInterval; // minimum blocks between drips
        uint16 dripBps; // max fraction of reserve released per drip (basis points, <= 10_000)
    }

    /// @dev Per-pool escrow of the captured toxicity premium, held by the hook
    /// as ERC-6909 claims between capture (toxic regime) and drip (quiet regime).
    struct SmoothingReserve {
        uint128 reserve0;
        uint128 reserve1;
        uint40 lastDripBlock;
    }

    event PoolPolicyInitialized(PoolId indexed poolId, uint24 baseFee, uint24 minFee, uint24 maxFee);
    event FeeOverrideApplied(PoolId indexed poolId, bool zeroForOne, uint24 fee, int56 pressure, uint8 regime);
    event DirectionalPressureUpdated(PoolId indexed poolId, int24 tickMove, int56 pressure, int24 referenceTick);
    event RiskRegimeChanged(PoolId indexed poolId, uint8 oldRegime, uint8 newRegime);
    event SmoothingConfigured(PoolId indexed poolId, bool enabled, uint32 dripBlockInterval, uint16 dripBps);
    event PremiumCaptured(PoolId indexed poolId, uint128 amount0, uint128 amount1);
    event DripReleased(PoolId indexed poolId, uint128 amount0, uint128 amount1);
    event ReactiveExecutorSet(PoolId indexed poolId, address indexed executor);
    event ReactiveActionApplied(PoolId indexed poolId, uint8 actionType, uint40 atBlock);
    event ReactiveActionRejected(PoolId indexed poolId, uint8 actionType, uint8 reason);
    event PolicyModeUpdated(PoolId indexed poolId, uint8 mode, address indexed caller);

    /// @dev Reactive-automation action types (for events) and rejection reasons.
    uint8 private constant ACTION_DRIP = 1;
    uint8 private constant ACTION_POLICY_MODE = 2;
    uint8 private constant REASON_NOT_QUIET = 1;
    uint8 private constant REASON_NOT_ELIGIBLE = 2;
    uint8 private constant REASON_BAD_MODE = 3;

    /// @dev Transient storage slot for the premium capture amount to pass from beforeSwap to afterSwap.
    /// keccak256(abi.encode(uint256(keccak256("DirectionalToxicityShield.premiumCapture")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PREMIUM_CAPTURE_SLOT = 0x8a35acfbc15ff81a39ae7d344fd709f28e8600b4aa8c65c6b64bfe7fe36bd900;
    uint256 private constant PREMIUM_BPS_OFFSET = 0;
    uint256 private constant PREMIUM_APPLY_OFFSET = 1;
    uint256 private constant PRE_SWAP_QUIET_OFFSET = 2;

    mapping(PoolId poolId => FeePolicy policy) internal feePolicies;
    mapping(PoolId poolId => DirectionalState state) internal directionalStates;
    mapping(PoolId poolId => address configurer) internal poolConfigurers;
    mapping(PoolId poolId => SmoothingConfig config) internal smoothingConfigs;
    mapping(PoolId poolId => SmoothingReserve reserve) internal smoothingReserves;
    /// @dev Per-pool address authorized to trigger bounded Reactive-automation
    /// actions (quiet drip, policy mode). Set by the pool configurer. Zero means
    /// no Reactive executor is wired and the external automation entrypoints revert.
    mapping(PoolId poolId => address executor) internal reactiveExecutors;

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
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal pure override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        return BaseHook.beforeInitialize.selector;
    }

    function _afterInitialize(address sender, PoolKey calldata key, uint160, int24 tick)
        internal
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        FeePolicy memory policy = _defaultPolicy();
        _validatePolicy(policy);

        feePolicies[poolId] = policy;
        // Capture the initializer as the pool configurer. Init hookData is not
        // available in this v4-core version, so this is the only trust anchor
        // for later opt-in smoothing configuration.
        poolConfigurers[poolId] = sender;
        directionalStates[poolId] = DirectionalState({
            referenceTick: tick,
            lastTick: tick,
            pressure: 0,
            lastUpdateTime: uint40(block.timestamp),
            lastFee: policy.baseFee,
            regime: 0,
            lastPressureBlock: 0
        });

        emit PoolPolicyInitialized(poolId, policy.baseFee, policy.minFee, policy.maxFee);

        return BaseHook.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        (uint24 fee, int56 effectivePressure) = _previewFeeAndPressure(poolId, params.zeroForOne);
        DirectionalState storage state = directionalStates[poolId];
        state.lastFee = fee;

        FeePolicy memory policy = feePolicies[poolId];
        uint8 regime = _regimeFor(effectivePressure, policy.maxPressure);

        emit FeeOverrideApplied(poolId, params.zeroForOne, fee, effectivePressure, regime);

        // Store pre-swap quiet flag for drip eligibility in afterSwap.
        _setTransientPreSwapQuiet(regime == 0);

        // Smoothing capture: when enabled and the swap is aligned (fee > baseFee),
        // set the LP fee to baseFee only and store the premium fraction in transient
        // storage for afterSwap to capture.
        SmoothingConfig memory smoothing = smoothingConfigs[poolId];
        if (smoothing.enabled && fee > policy.baseFee && regime > 0) {
            // Premium fraction in bps: how much of the unspecified output to skim.
            // premium = (fee - baseFee) / fee * 10_000 (in bps of the unspecified amount)
            uint256 premiumBps = (uint256(fee - policy.baseFee) * 10_000) / uint256(fee);
            _setTransientPremiumBps(premiumBps);
            _setTransientApplyCapture(true);

            // LPs receive baseFee; the premium is captured in afterSwap.
            return (
                BaseHook.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                policy.baseFee | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
        }

        // No capture: clear transient state and pass full fee to LPs.
        _setTransientApplyCapture(false);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();

        // Read the pre-swap quiet flag set by _beforeSwap (based on effective/decayed regime).
        bool wasQuiet = _transientPreSwapQuiet();

        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        _updatePressure(poolId, currentTick);

        // Premium capture: if beforeSwap flagged this swap for capture, skim the
        // premium from the unspecified currency and escrow it in the reserve.
        if (_transientApplyCapture()) {
            // Reset transient state
            uint256 premiumBps = _transientPremiumBps();
            _setTransientApplyCapture(false);
            _setTransientPremiumBps(0);

            // Identify unspecified currency and its absolute amount (mirrors BaseDynamicAfterFee)
            bool exactInput = params.amountSpecified < 0;
            (Currency unspecified, int128 unspecifiedAmount) =
                (exactInput == params.zeroForOne) ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());

            // For exactInput, unspecified is output (positive = tokens out to swapper).
            // For exactOutput, unspecified is input (negative = tokens in from swapper).
            uint256 absUnspecified;
            if (unspecifiedAmount < 0) {
                absUnspecified = uint256(uint128(-unspecifiedAmount));
            } else {
                absUnspecified = uint256(uint128(unspecifiedAmount));
            }

            // Compute premium to capture
            uint256 feeAmount = (absUnspecified * premiumBps) / 10_000;
            if (feeAmount == 0) return (BaseHook.afterSwap.selector, 0);

            // Take ERC-6909 claims into this hook
            unspecified.take(poolManager, address(this), feeAmount, true);

            // Credit the smoothing reserve
            SmoothingReserve storage reserve = smoothingReserves[poolId];
            if (unspecified == key.currency0) {
                reserve.reserve0 += uint128(feeAmount);
            } else {
                reserve.reserve1 += uint128(feeAmount);
            }

            emit PremiumCaptured(
                poolId,
                unspecified == key.currency0 ? uint128(feeAmount) : 0,
                unspecified == key.currency1 ? uint128(feeAmount) : 0
            );

            return (BaseHook.afterSwap.selector, feeAmount.toInt128());
        }

        // Drip path: release a bounded slice of the reserve to in-range LPs
        // when the pool was in quiet regime at the start of this swap.
        if (wasQuiet) {
            _tryDrip(key, poolId);
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    function getFeePolicy(PoolId poolId) external view returns (FeePolicy memory) {
        return feePolicies[poolId];
    }

    /// @notice The address that initialized the pool and may configure smoothing.
    function getPoolConfigurer(PoolId poolId) external view returns (address) {
        return poolConfigurers[poolId];
    }

    /// @notice Current opt-in smoothing configuration for a pool (disabled by default).
    function getSmoothingConfig(PoolId poolId) external view returns (SmoothingConfig memory) {
        return smoothingConfigs[poolId];
    }

    /// @notice Current escrowed smoothing reserve for a pool.
    function getSmoothingReserve(PoolId poolId) external view returns (SmoothingReserve memory) {
        return smoothingReserves[poolId];
    }

    /// @notice Configure (or disable) yield smoothing for a pool. Restricted to
    /// the pool configurer captured at initialization. Smoothing is opt-in:
    /// pools that never call this keep the pure directional-fee behavior.
    function configureSmoothing(PoolKey calldata key, SmoothingConfig calldata config) external {
        PoolId poolId = key.toId();
        if (msg.sender != poolConfigurers[poolId]) revert NotPoolConfigurer();
        _validateSmoothingConfig(config);
        smoothingConfigs[poolId] = config;
        emit SmoothingConfigured(poolId, config.enabled, config.dripBlockInterval, config.dripBps);
    }

    /// @notice Wire the per-pool Reactive executor authorized to trigger bounded
    /// automation actions (quiet drip, policy mode). Restricted to the pool
    /// configurer. Set to address(0) to disable Reactive automation for the pool.
    function setReactiveExecutor(PoolKey calldata key, address executor) external {
        PoolId poolId = key.toId();
        if (msg.sender != poolConfigurers[poolId]) revert NotPoolConfigurer();
        reactiveExecutors[poolId] = executor;
        emit ReactiveExecutorSet(poolId, executor);
    }

    /// @notice The Reactive executor authorized for a pool (zero if unset).
    function getReactiveExecutor(PoolId poolId) external view returns (address) {
        return reactiveExecutors[poolId];
    }

    function getDirectionalState(PoolId poolId) external view returns (DirectionalState memory) {
        return directionalStates[poolId];
    }

    function getCurrentRegime(PoolId poolId) external view returns (uint8) {
        return directionalStates[poolId].regime;
    }

    /// @notice The effective (time-decayed) risk regime as of the current block,
    /// matching what {triggerQuietDrip} recomputes. Differs from
    /// {getCurrentRegime} (the last stored regime) when pressure has decayed but
    /// no swap has refreshed state since. Useful for Reactive monitors and
    /// integrators deciding whether the pool is genuinely quiet.
    function getEffectiveRegime(PoolId poolId) external view returns (uint8) {
        FeePolicy memory policy = feePolicies[poolId];
        DirectionalState memory state = directionalStates[poolId];
        return _regimeFor(_effectivePressure(state, policy), policy.maxPressure);
    }

    function previewFee(PoolKey calldata key, SwapParams calldata params) external view returns (uint24) {
        return _previewFee(key.toId(), params.zeroForOne);
    }

    function _previewFee(PoolId poolId, bool zeroForOne) private view returns (uint24) {
        (uint24 fee,) = _previewFeeAndPressure(poolId, zeroForOne);
        return fee;
    }

    function _previewFeeAndPressure(PoolId poolId, bool zeroForOne)
        private
        view
        returns (uint24 fee, int56 effectivePressure)
    {
        FeePolicy memory policy = feePolicies[poolId];
        DirectionalState memory state = directionalStates[poolId];

        if (policy.liquidityFloor > 0 && poolManager.getLiquidity(poolId) < policy.liquidityFloor) {
            return (_clampFee(policy.baseFee, policy), 0);
        }

        effectivePressure = _effectivePressure(state, policy);
        if (effectivePressure == 0) return (_clampFee(policy.baseFee, policy), 0);

        uint24 adjustment = _feeAdjustment(effectivePressure, policy);
        bool aligned = effectivePressure > 0 ? !zeroForOne : zeroForOne;

        if (aligned) {
            uint256 increased = uint256(policy.baseFee) + adjustment;
            fee = _clampFee(increased > type(uint24).max ? type(uint24).max : uint24(increased), policy);
        } else {
            uint24 decreased = policy.baseFee > adjustment ? policy.baseFee - adjustment : 0;
            fee = _clampFee(decreased, policy);
        }
    }

    function _feeAdjustment(int56 pressure, FeePolicy memory policy) private pure returns (uint24) {
        uint56 pressureAbs = pressure < 0 ? uint56(-pressure) : uint56(pressure);
        uint256 rawAdjustment = uint256(pressureAbs) * policy.pressureScale;
        return rawAdjustment > policy.maxFeeStep ? policy.maxFeeStep : uint24(rawAdjustment);
    }

    function _clampFee(uint24 fee, FeePolicy memory policy) private pure returns (uint24) {
        if (fee < policy.minFee) return policy.minFee;
        if (fee > policy.maxFee) return policy.maxFee;
        return fee;
    }

    function _effectivePressure(DirectionalState memory state, FeePolicy memory policy) private view returns (int56) {
        uint40 elapsed = uint40(block.timestamp) - state.lastUpdateTime;
        if (elapsed >= policy.decayWindow) return 0;
        if (elapsed < policy.filterWindow) return state.pressure;

        return int56((int256(state.pressure) * int256(uint256(policy.decayFactor))) / int256(uint256(1_000_000)));
    }

    function _updatePressure(PoolId poolId, int24 currentTick) internal {
        FeePolicy memory policy = feePolicies[poolId];
        DirectionalState storage state = directionalStates[poolId];

        // Per-block accumulation cap: only the first afterSwap per block accrues pressure.
        // Subsequent same-block swaps still progress lastTick (so the next block sees the
        // correct delta) but cannot re-add pressure, preventing single-block stuffing from
        // blowing past maxPressure via a multi-swap sandwich.
        if (uint40(block.number) == state.lastPressureBlock) {
            state.lastTick = currentTick;
            return;
        }

        int24 tickMove = currentTick - state.referenceTick;
        int56 introducedPressure =
            _absTickMove(tickMove) < uint24(policy.majorMoveThreshold) ? int56(0) : int56(tickMove);

        uint40 nowTime = uint40(block.timestamp);
        uint40 elapsed = nowTime - state.lastUpdateTime;
        int56 decayedPressure = state.pressure;

        if (elapsed >= policy.decayWindow) {
            decayedPressure = 0;
            state.referenceTick = currentTick;
        } else if (elapsed >= policy.filterWindow) {
            decayedPressure =
                int56((int256(decayedPressure) * int256(uint256(policy.decayFactor))) / int256(uint256(1_000_000)));
            state.referenceTick = currentTick;
        }

        int56 nextPressure = _clampPressure(decayedPressure + introducedPressure, policy.maxPressure);
        uint8 oldRegime = state.regime;
        uint8 newRegime = _regimeFor(nextPressure, policy.maxPressure);

        state.lastTick = currentTick;
        state.pressure = nextPressure;
        state.lastUpdateTime = nowTime;
        state.lastPressureBlock = uint40(block.number);
        state.regime = newRegime;

        emit DirectionalPressureUpdated(poolId, tickMove, nextPressure, state.referenceTick);
        if (oldRegime != newRegime) emit RiskRegimeChanged(poolId, oldRegime, newRegime);
    }

    function _clampPressure(int56 pressure, int24 maxPressure) private pure returns (int56) {
        int56 max = int56(maxPressure);
        if (pressure > max) return max;
        if (pressure < -max) return -max;
        return pressure;
    }

    function _regimeFor(int56 pressure, int24 maxPressure) private pure returns (uint8) {
        uint56 pressureAbs = pressure < 0 ? uint56(-pressure) : uint56(pressure);
        if (pressureAbs == 0) return 0;
        if (pressureAbs >= uint24(maxPressure) / 2) return 2;
        return 1;
    }

    function _absTickMove(int24 tickMove) private pure returns (uint24) {
        return tickMove < 0 ? uint24(-tickMove) : uint24(tickMove);
    }

    function _validatePolicy(FeePolicy memory policy) internal pure {
        if (policy.minFee > policy.baseFee || policy.baseFee > policy.maxFee) {
            revert InvalidFeeBounds();
        }
        if (policy.maxFeeStep == 0) revert InvalidStepSize();
        if (policy.pressureScale == 0 || policy.maxPressure <= 0) {
            revert InvalidPressureScale();
        }
        if (policy.decayFactor > 1_000_000) revert InvalidDecayFactor();
        if (policy.decayWindow <= policy.filterWindow) revert InvalidDecayWindow();
        if (policy.majorMoveThreshold < 0) revert InvalidMajorMoveThreshold();
    }

    /// @dev Validate smoothing knobs. Only meaningful when enabled; a disabled
    /// config is always valid (it is a no-op opt-out).
    function _validateSmoothingConfig(SmoothingConfig memory config) internal pure {
        if (!config.enabled) return;
        if (config.dripBlockInterval == 0) revert InvalidDripInterval();
        if (config.dripBps == 0 || config.dripBps > 10_000) revert InvalidDripBps();
    }

    // ─── Transient storage helpers (premium capture) ───────────────────────────

    function _transientPremiumBps() internal view returns (uint256) {
        return PREMIUM_CAPTURE_SLOT.offset(PREMIUM_BPS_OFFSET).asUint256().tload();
    }

    function _transientApplyCapture() internal view returns (bool) {
        return PREMIUM_CAPTURE_SLOT.offset(PREMIUM_APPLY_OFFSET).asBoolean().tload();
    }

    function _setTransientPremiumBps(uint256 value) internal {
        PREMIUM_CAPTURE_SLOT.offset(PREMIUM_BPS_OFFSET).asUint256().tstore(value);
    }

    function _setTransientApplyCapture(bool value) internal {
        PREMIUM_CAPTURE_SLOT.offset(PREMIUM_APPLY_OFFSET).asBoolean().tstore(value);
    }

    function _transientPreSwapQuiet() internal view returns (bool) {
        return PREMIUM_CAPTURE_SLOT.offset(PRE_SWAP_QUIET_OFFSET).asBoolean().tload();
    }

    function _setTransientPreSwapQuiet(bool value) internal {
        PREMIUM_CAPTURE_SLOT.offset(PRE_SWAP_QUIET_OFFSET).asBoolean().tstore(value);
    }

    // ─── Drip logic ────────────────────────────────────────────────────────────

    /// @dev Attempt to drip escrowed premium to in-range LPs. Conditions:
    /// - smoothing enabled
    /// - reserve has funds
    /// - at least dripBlockInterval blocks since last drip
    /// - pool has in-range liquidity (donate reverts otherwise)
    /// Note: regime check (quiet) is done by the caller before invoking this.
    /// Runs inside the afterSwap PoolManager unlock context.
    function _tryDrip(PoolKey calldata key, PoolId poolId) internal {
        if (!_dripReady(poolId)) return;
        _performDrip(key, poolId);
    }

    /// @dev Shared eligibility gate: smoothing enabled, reserve non-empty, and
    /// the per-pool cooldown elapsed. In-range liquidity and dust are only
    /// knowable at donate time, so they are checked inside {_performDrip}.
    function _dripReady(PoolId poolId) internal view returns (bool) {
        SmoothingConfig memory config = smoothingConfigs[poolId];
        if (!config.enabled) return false;

        SmoothingReserve storage reserve = smoothingReserves[poolId];
        if (reserve.reserve0 == 0 && reserve.reserve1 == 0) return false;

        if (uint40(block.number) - reserve.lastDripBlock < config.dripBlockInterval) return false;
        return true;
    }

    /// @dev Execute a bounded drip. MUST run inside a PoolManager unlock context
    /// (the afterSwap path is already unlocked; the Reactive path acquires an
    /// unlock via {unlockCallback}). Safe no-op when there is no in-range
    /// liquidity or the bounded slice rounds to dust.
    function _performDrip(PoolKey memory key, PoolId poolId) internal {
        SmoothingConfig memory config = smoothingConfigs[poolId];
        SmoothingReserve storage reserve = smoothingReserves[poolId];

        // Guard: donate reverts with zero in-range liquidity
        if (poolManager.getLiquidity(poolId) == 0) return;

        // Compute drip amounts (capped fraction of reserve)
        uint128 drip0 = uint128((uint256(reserve.reserve0) * config.dripBps) / 10_000);
        uint128 drip1 = uint128((uint256(reserve.reserve1) * config.dripBps) / 10_000);

        // Skip dust drips
        if (drip0 == 0 && drip1 == 0) return;

        // Settle ERC-6909 claims (burn them to credit the PoolManager)
        if (drip0 > 0) {
            key.currency0.settle(poolManager, address(this), drip0, true);
        }
        if (drip1 > 0) {
            key.currency1.settle(poolManager, address(this), drip1, true);
        }

        // Donate to in-range LPs
        poolManager.donate(key, drip0, drip1, "");

        // Update reserve
        reserve.reserve0 -= drip0;
        reserve.reserve1 -= drip1;
        reserve.lastDripBlock = uint40(block.number);

        emit DripReleased(poolId, drip0, drip1);
    }

    // ─── Reactive automation entrypoints ───────────────────────────────────────

    /// @notice Reactive-automation entrypoint: release a bounded slice of
    /// escrowed premium to in-range LPs when the pool is in a quiet regime.
    /// Solves the stranded-reserve problem: the in-swap drip only fires if a
    /// swap happens during a quiet regime, so a genuinely idle pool would never
    /// release escrow. A Reactive Smart Contract (CRON or RiskRegimeChanged)
    /// calls this through the authorized executor.
    ///
    /// The hook RECOMPUTES quiet/eligibility from its own state; the callback is
    /// only a trigger, never a source of truth. A failed/rejected action is a
    /// bounded no-op and never affects the core fee path.
    function triggerQuietDrip(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        address executor = reactiveExecutors[poolId];
        if (executor == address(0) || msg.sender != executor) revert NotReactiveExecutor();

        // Recompute the quiet regime from current (time-decayed) pressure.
        FeePolicy memory policy = feePolicies[poolId];
        DirectionalState memory state = directionalStates[poolId];
        int56 effectivePressure = _effectivePressure(state, policy);
        if (_regimeFor(effectivePressure, policy.maxPressure) != 0) {
            emit ReactiveActionRejected(poolId, ACTION_DRIP, REASON_NOT_QUIET);
            return;
        }

        if (!_dripReady(poolId)) {
            emit ReactiveActionRejected(poolId, ACTION_DRIP, REASON_NOT_ELIGIBLE);
            return;
        }

        // Not in an unlock context here; acquire one and drip in unlockCallback.
        poolManager.unlock(abi.encode(key));
        emit ReactiveActionApplied(poolId, ACTION_DRIP, uint40(block.number));
    }

    /// @notice PoolManager unlock callback used only by {triggerQuietDrip}.
    /// Strictly guarded to the PoolManager; performs the settle+donate body.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        PoolKey memory key = abi.decode(data, (PoolKey));
        _performDrip(key, key.toId());
        return "";
    }

    /// @notice Reactive-automation entrypoint: switch the pool's fee policy among
    /// a small set of pre-approved, bounded presets. Cannot set arbitrary fee
    /// values. Only callable by the per-pool Reactive executor. All presets
    /// preserve the {_validatePolicy} invariants.
    function applyPolicyMode(PoolKey calldata key, uint8 mode) external {
        PoolId poolId = key.toId();
        address executor = reactiveExecutors[poolId];
        if (executor == address(0) || msg.sender != executor) revert NotReactiveExecutor();
        if (mode > 2) {
            emit ReactiveActionRejected(poolId, ACTION_POLICY_MODE, REASON_BAD_MODE);
            return;
        }

        (uint24 newMaxFee, uint24 newMaxFeeStep) = _policyModePreset(mode);
        FeePolicy storage policy = feePolicies[poolId];
        policy.maxFee = newMaxFee;
        policy.maxFeeStep = newMaxFeeStep;
        _validatePolicy(policy);

        emit PolicyModeUpdated(poolId, mode, msg.sender);
        emit ReactiveActionApplied(poolId, ACTION_POLICY_MODE, uint40(block.number));
    }

    /// @dev Bounded fee-policy presets selectable by Reactive automation.
    /// mode 0 NORMAL, 1 GUARDED, 2 DEFENSIVE. Returns (maxFee, maxFeeStep).
    function _policyModePreset(uint8 mode) private pure returns (uint24 maxFee, uint24 maxFeeStep) {
        if (mode == 1) return (20_000, 1_000);
        if (mode == 2) return (30_000, 2_000);
        return (10_000, 500);
    }

    function _defaultPolicy() private pure returns (FeePolicy memory) {
        return FeePolicy({
            baseFee: 3000,
            minFee: 500,
            maxFee: 10000,
            maxFeeStep: 500,
            pressureScale: 10,
            maxPressure: 500,
            decayFactor: 500_000,
            filterWindow: 30,
            decayWindow: 5 minutes,
            liquidityFloor: 1e18,
            majorMoveThreshold: 5
        });
    }
}
