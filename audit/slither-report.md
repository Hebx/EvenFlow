**THIS CHECKLIST IS NOT COMPLETE**. Use `--show-ignored-findings` to show all the results.
Summary
 - [incorrect-equality](#incorrect-equality) (3 results) (Medium)
 - [reentrancy-no-eth](#reentrancy-no-eth) (1 results) (Medium)
 - [unused-return](#unused-return) (9 results) (Medium)
 - [missing-zero-check](#missing-zero-check) (2 results) (Low)
 - [reentrancy-benign](#reentrancy-benign) (1 results) (Low)
 - [reentrancy-events](#reentrancy-events) (3 results) (Low)
 - [timestamp](#timestamp) (9 results) (Low)
 - [missing-inheritance](#missing-inheritance) (1 results) (Informational)
## incorrect-equality
Impact: Medium
Confidence: High
 - [ ] ID-0
[DirectionalToxicityShield._updatePressure(PoolId,int24)](.src/DirectionalToxicityShield.sol#L403-L445) uses a dangerous strict equality:
	- [uint40(block.number) == state.lastPressureBlock](.src/DirectionalToxicityShield.sol#L411)

.src/DirectionalToxicityShield.sol#L403-L445


 - [ ] ID-1
[DirectionalToxicityShield._regimeFor(int56,int24)](.src/DirectionalToxicityShield.sol#L454-L459) uses a dangerous strict equality:
	- [pressureAbs == 0](.src/DirectionalToxicityShield.sol#L456)

.src/DirectionalToxicityShield.sol#L454-L459


 - [ ] ID-2
[DirectionalToxicityShield._previewFeeAndPressure(PoolId,bool)](.src/DirectionalToxicityShield.sol#L356-L381) uses a dangerous strict equality:
	- [effectivePressure == 0](.src/DirectionalToxicityShield.sol#L369)

.src/DirectionalToxicityShield.sol#L356-L381


## reentrancy-no-eth
Impact: Medium
Confidence: Medium
 - [ ] ID-3
Reentrancy in [DirectionalToxicityShield._performDrip(PoolKey,PoolId)](.src/DirectionalToxicityShield.sol#L544-L575):
	External calls:
	- [key.currency0.settle(poolManager,address(this),drip0,true)](.src/DirectionalToxicityShield.sol#L560)
	- [key.currency1.settle(poolManager,address(this),drip1,true)](.src/DirectionalToxicityShield.sol#L563)
	- [poolManager.donate(key,drip0,drip1,)](.src/DirectionalToxicityShield.sol#L567)
	State variables written after the call(s):
	- [reserve.reserve0 -= drip0](.src/DirectionalToxicityShield.sol#L570)
	[DirectionalToxicityShield.smoothingReserves](.src/DirectionalToxicityShield.sol#L112) can be used in cross function reentrancies:
	- [DirectionalToxicityShield._afterSwap(address,PoolKey,SwapParams,BalanceDelta,bytes)](.src/DirectionalToxicityShield.sol#L215-L281)
	- [DirectionalToxicityShield._dripReady(PoolId)](.src/DirectionalToxicityShield.sol#L529-L538)
	- [DirectionalToxicityShield._performDrip(PoolKey,PoolId)](.src/DirectionalToxicityShield.sol#L544-L575)
	- [DirectionalToxicityShield.getSmoothingReserve(PoolId)](.src/DirectionalToxicityShield.sol#L298-L300)
	- [reserve.reserve1 -= drip1](.src/DirectionalToxicityShield.sol#L571)
	[DirectionalToxicityShield.smoothingReserves](.src/DirectionalToxicityShield.sol#L112) can be used in cross function reentrancies:
	- [DirectionalToxicityShield._afterSwap(address,PoolKey,SwapParams,BalanceDelta,bytes)](.src/DirectionalToxicityShield.sol#L215-L281)
	- [DirectionalToxicityShield._dripReady(PoolId)](.src/DirectionalToxicityShield.sol#L529-L538)
	- [DirectionalToxicityShield._performDrip(PoolKey,PoolId)](.src/DirectionalToxicityShield.sol#L544-L575)
	- [DirectionalToxicityShield.getSmoothingReserve(PoolId)](.src/DirectionalToxicityShield.sol#L298-L300)
	- [reserve.lastDripBlock = uint40(block.number)](.src/DirectionalToxicityShield.sol#L572)
	[DirectionalToxicityShield.smoothingReserves](.src/DirectionalToxicityShield.sol#L112) can be used in cross function reentrancies:
	- [DirectionalToxicityShield._afterSwap(address,PoolKey,SwapParams,BalanceDelta,bytes)](.src/DirectionalToxicityShield.sol#L215-L281)
	- [DirectionalToxicityShield._dripReady(PoolId)](.src/DirectionalToxicityShield.sol#L529-L538)
	- [DirectionalToxicityShield._performDrip(PoolKey,PoolId)](.src/DirectionalToxicityShield.sol#L544-L575)
	- [DirectionalToxicityShield.getSmoothingReserve(PoolId)](.src/DirectionalToxicityShield.sol#L298-L300)

.src/DirectionalToxicityShield.sol#L544-L575


## unused-return
Impact: Medium
Confidence: Medium
 - [ ] ID-4
[RegisNezlobinComparator._calculateDynamicFee(PoolId,bool)](.src/comparators/PriorArtComparators.sol#L193-L210) ignores return value by [(None,currentTick,None,None) = poolManager.getSlot0(poolId)](.src/comparators/PriorArtComparators.sol#L194)

.src/comparators/PriorArtComparators.sol#L193-L210


 - [ ] ID-5
[RegisNezlobinComparator._beforeSwap(address,PoolKey,SwapParams,bytes)](.src/comparators/PriorArtComparators.sol#L174-L191) ignores return value by [(None,currentTick,None,None) = poolManager.getSlot0(poolId)](.src/comparators/PriorArtComparators.sol#L184)

.src/comparators/PriorArtComparators.sol#L174-L191


 - [ ] ID-6
[VpinDynamicFeeComparator._afterSwap(address,PoolKey,SwapParams,BalanceDelta,bytes)](.src/comparators/PriorArtComparators.sol#L385-L405) ignores return value by [(None,currentTick,None,None) = poolManager.getSlot0(poolId)](.src/comparators/PriorArtComparators.sol#L399)

.src/comparators/PriorArtComparators.sol#L385-L405


 - [ ] ID-7
[DirectionalToxicityShield._afterSwap(address,PoolKey,SwapParams,BalanceDelta,bytes)](.src/DirectionalToxicityShield.sol#L215-L281) ignores return value by [(None,currentTick,None,None) = poolManager.getSlot0(poolId)](.src/DirectionalToxicityShield.sol#L225)

.src/DirectionalToxicityShield.sol#L215-L281


 - [ ] ID-8
[VpinDynamicFeeComparator._beforeSwap(address,PoolKey,SwapParams,bytes)](.src/comparators/PriorArtComparators.sol#L364-L383) ignores return value by [(None,currentTick,None,None) = poolManager.getSlot0(poolId)](.src/comparators/PriorArtComparators.sol#L376)

.src/comparators/PriorArtComparators.sol#L364-L383


 - [ ] ID-9
[JdsAsymmetricFeesComparator._setFee(PoolId)](.src/comparators/PriorArtComparators.sol#L94-L122) ignores return value by [(currentSqrtPriceX96,None,None,None) = poolManager.getSlot0(poolId)](.src/comparators/PriorArtComparators.sol#L95)

.src/comparators/PriorArtComparators.sol#L94-L122


 - [ ] ID-10
[InfHookNezlobinComparator._beforeSwap(address,PoolKey,SwapParams,bytes)](.src/comparators/PriorArtComparators.sol#L261-L283) ignores return value by [(None,currentTick,None,None) = poolManager.getSlot0(poolId)](.src/comparators/PriorArtComparators.sol#L271)

.src/comparators/PriorArtComparators.sol#L261-L283


 - [ ] ID-11
[DirectionalToxicityShield._performDrip(PoolKey,PoolId)](.src/DirectionalToxicityShield.sol#L544-L575) ignores return value by [poolManager.donate(key,drip0,drip1,)](.src/DirectionalToxicityShield.sol#L567)

.src/DirectionalToxicityShield.sol#L544-L575


 - [ ] ID-12
[DirectionalToxicityShield.triggerQuietDrip(PoolKey)](.src/DirectionalToxicityShield.sol#L589-L611) ignores return value by [poolManager.unlock(abi.encode(key))](.src/DirectionalToxicityShield.sol#L609)

.src/DirectionalToxicityShield.sol#L589-L611


## missing-zero-check
Impact: Low
Confidence: Medium
 - [ ] ID-13
[CallbackSink.onPing(address).sender](.src/reactive/CallbackSink.sol#L27) lacks a zero-check on :
		- [lastSender = sender](.src/reactive/CallbackSink.sol#L29)

.src/reactive/CallbackSink.sol#L27


 - [ ] ID-14
[LegacyCallbackProbe.constructor(uint256,uint256,address).sink_](.src/reactive/LegacyCallbackProbe.sol#L25) lacks a zero-check on :
		- [sink = sink_](.src/reactive/LegacyCallbackProbe.sol#L28)

.src/reactive/LegacyCallbackProbe.sol#L25


## reentrancy-benign
Impact: Low
Confidence: Medium
 - [ ] ID-15
Reentrancy in [DirectionalToxicityShield._afterSwap(address,PoolKey,SwapParams,BalanceDelta,bytes)](.src/DirectionalToxicityShield.sol#L215-L281):
	External calls:
	- [unspecified.take(poolManager,address(this),feeAmount,true)](.src/DirectionalToxicityShield.sol#L255)
	State variables written after the call(s):
	- [reserve.reserve0 += uint128(feeAmount)](.src/DirectionalToxicityShield.sol#L260)
	- [reserve.reserve1 += uint128(feeAmount)](.src/DirectionalToxicityShield.sol#L262)

.src/DirectionalToxicityShield.sol#L215-L281


## reentrancy-events
Impact: Low
Confidence: Medium
 - [ ] ID-16
Reentrancy in [DirectionalToxicityShield._afterSwap(address,PoolKey,SwapParams,BalanceDelta,bytes)](.src/DirectionalToxicityShield.sol#L215-L281):
	External calls:
	- [unspecified.take(poolManager,address(this),feeAmount,true)](.src/DirectionalToxicityShield.sol#L255)
	Event emitted after the call(s):
	- [PremiumCaptured(poolId,uint128(feeAmount),uint128(feeAmount))](.src/DirectionalToxicityShield.sol#L265-L269)
	- [PremiumCaptured(poolId,0,0)](.src/DirectionalToxicityShield.sol#L265-L269)

.src/DirectionalToxicityShield.sol#L215-L281


 - [ ] ID-17
Reentrancy in [DirectionalToxicityShield._performDrip(PoolKey,PoolId)](.src/DirectionalToxicityShield.sol#L544-L575):
	External calls:
	- [key.currency0.settle(poolManager,address(this),drip0,true)](.src/DirectionalToxicityShield.sol#L560)
	- [key.currency1.settle(poolManager,address(this),drip1,true)](.src/DirectionalToxicityShield.sol#L563)
	- [poolManager.donate(key,drip0,drip1,)](.src/DirectionalToxicityShield.sol#L567)
	Event emitted after the call(s):
	- [DripReleased(poolId,drip0,drip1)](.src/DirectionalToxicityShield.sol#L574)

.src/DirectionalToxicityShield.sol#L544-L575


 - [ ] ID-18
Reentrancy in [DirectionalToxicityShield.triggerQuietDrip(PoolKey)](.src/DirectionalToxicityShield.sol#L589-L611):
	External calls:
	- [poolManager.unlock(abi.encode(key))](.src/DirectionalToxicityShield.sol#L609)
	Event emitted after the call(s):
	- [ReactiveActionApplied(poolId,ACTION_DRIP,uint40(block.number))](.src/DirectionalToxicityShield.sol#L610)

.src/DirectionalToxicityShield.sol#L589-L611


## timestamp
Impact: Low
Confidence: Medium
 - [ ] ID-19
[DirectionalToxicityShield._regimeFor(int56,int24)](.src/DirectionalToxicityShield.sol#L454-L459) uses timestamp for comparisons
	Dangerous comparisons:
	- [pressureAbs == 0](.src/DirectionalToxicityShield.sol#L456)
	- [pressureAbs >= uint24(maxPressure) / 2](.src/DirectionalToxicityShield.sol#L457)
	- [pressure < 0](.src/DirectionalToxicityShield.sol#L455)

.src/DirectionalToxicityShield.sol#L454-L459


 - [ ] ID-20
[RegisNezlobinComparator._beforeSwap(address,PoolKey,SwapParams,bytes)](.src/comparators/PriorArtComparators.sol#L174-L191) uses timestamp for comparisons
	Dangerous comparisons:
	- [lastBlockTimestamps[poolId] < block.timestamp](.src/comparators/PriorArtComparators.sol#L182)

.src/comparators/PriorArtComparators.sol#L174-L191


 - [ ] ID-21
[DirectionalToxicityShield._clampFee(uint24,DirectionalToxicityShield.FeePolicy)](.src/DirectionalToxicityShield.sol#L389-L393) uses timestamp for comparisons
	Dangerous comparisons:
	- [fee < policy.minFee](.src/DirectionalToxicityShield.sol#L390)
	- [fee > policy.maxFee](.src/DirectionalToxicityShield.sol#L391)

.src/DirectionalToxicityShield.sol#L389-L393


 - [ ] ID-22
[DirectionalToxicityShield._previewFeeAndPressure(PoolId,bool)](.src/DirectionalToxicityShield.sol#L356-L381) uses timestamp for comparisons
	Dangerous comparisons:
	- [effectivePressure == 0](.src/DirectionalToxicityShield.sol#L369)
	- [effectivePressure > 0](.src/DirectionalToxicityShield.sol#L372)
	- [increased > type()(uint24).max](.src/DirectionalToxicityShield.sol#L376)
	- [policy.baseFee > adjustment](.src/DirectionalToxicityShield.sol#L378)

.src/DirectionalToxicityShield.sol#L356-L381


 - [ ] ID-23
[DirectionalToxicityShield._effectivePressure(DirectionalToxicityShield.DirectionalState,DirectionalToxicityShield.FeePolicy)](.src/DirectionalToxicityShield.sol#L395-L401) uses timestamp for comparisons
	Dangerous comparisons:
	- [elapsed >= policy.decayWindow](.src/DirectionalToxicityShield.sol#L397)
	- [elapsed < policy.filterWindow](.src/DirectionalToxicityShield.sol#L398)

.src/DirectionalToxicityShield.sol#L395-L401


 - [ ] ID-24
[DirectionalToxicityShield._beforeSwap(address,PoolKey,SwapParams,bytes)](.src/DirectionalToxicityShield.sol#L173-L213) uses timestamp for comparisons
	Dangerous comparisons:
	- [smoothing.enabled && fee > policy.baseFee && regime > 0](.src/DirectionalToxicityShield.sol#L195)

.src/DirectionalToxicityShield.sol#L173-L213


 - [ ] ID-25
[InfHookNezlobinComparator._beforeSwap(address,PoolKey,SwapParams,bytes)](.src/comparators/PriorArtComparators.sol#L261-L283) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp - poolToTimeStamp[poolId] > 1](.src/comparators/PriorArtComparators.sol#L269)

.src/comparators/PriorArtComparators.sol#L261-L283


 - [ ] ID-26
[DirectionalToxicityShield._updatePressure(PoolId,int24)](.src/DirectionalToxicityShield.sol#L403-L445) uses timestamp for comparisons
	Dangerous comparisons:
	- [elapsed >= policy.decayWindow](.src/DirectionalToxicityShield.sol#L424)
	- [elapsed >= policy.filterWindow](.src/DirectionalToxicityShield.sol#L427)

.src/DirectionalToxicityShield.sol#L403-L445


 - [ ] ID-27
[DirectionalToxicityShield._feeAdjustment(int56,DirectionalToxicityShield.FeePolicy)](.src/DirectionalToxicityShield.sol#L383-L387) uses timestamp for comparisons
	Dangerous comparisons:
	- [pressure < 0](.src/DirectionalToxicityShield.sol#L384)
	- [rawAdjustment > policy.maxFeeStep](.src/DirectionalToxicityShield.sol#L386)

.src/DirectionalToxicityShield.sol#L383-L387


## missing-inheritance
Impact: Informational
Confidence: High
 - [ ] ID-28
[DirectionalToxicityShield](.src/DirectionalToxicityShield.sol#L20-L667) should inherit from [IDirectionalToxicityShield](.src/reactive/IDirectionalToxicityShield.sol#L10-L17)

.src/DirectionalToxicityShield.sol#L20-L667


