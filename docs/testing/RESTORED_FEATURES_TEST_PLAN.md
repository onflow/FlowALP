# Test Plan for Restored Features from Dieter's AlpenFlow

## Overview

Based on the comprehensive analysis of the restored code and documentation, this test plan covers all features restored from Dieter's AlpenFlow implementation into TidalProtocol.

## Restored Features Summary

### 1. Core Infrastructure (100% Complete)
- ✅ `tokenState()` helper function - Automatic time updates
- ✅ `InternalPosition` as resource - With queued deposits
- ✅ Deposit rate limiting - 5% cap per transaction
- ✅ Position update queue - Async processing

### 2. Health Management (100% Complete)
- ✅ All 8 health calculation functions
- ✅ Health bounds (min/target/max) - Note: Stored in InternalPosition, not accessible via Position struct
- ✅ Rebalancing logic - Automatic position adjustment
- ✅ Source/sink integration - DeFi composability

### 3. Enhanced APIs (100% Complete)
- ✅ `depositAndPush()` - With draw-down sink option
- ✅ `withdrawAndPull()` - With top-up source option
- ✅ `availableBalance()` - With source integration
- ✅ Position struct methods - Relay pattern

## Test Implementation Strategy

### Phase 1: Core Functionality Tests

#### Test 1: tokenState() Helper Function
**What to test**: Automatic time-based state updates
**How to test**: 
- Cannot test directly (internal function)
- Test indirectly through deposit/withdraw operations with time advancement
- Verify interest accrual happens automatically

#### Test 2: Queued Deposits
**What to test**: Large deposits exceeding rate limits are queued
**How to test**:
- Create pool with low deposit rate
- Attempt large deposit via `depositAndPush()`
- Verify only 5% deposited immediately
- Note: Cannot directly verify queued amounts (internal state)

#### Test 3: Deposit Rate Limiting
**What to test**: 5% deposit cap enforcement
**How to test**:
- Set specific `depositRate` and `depositCapacityCap`
- Calculate expected 5% limit
- Verify deposits respect the limit

#### Test 4: Health Calculation Functions
**What to test**: All 8 public health functions
**Functions to test**:
1. `fundsRequiredForTargetHealth()`
2. `fundsRequiredForTargetHealthAfterWithdrawing()`
3. `fundsAvailableAboveTargetHealth()`
4. `fundsAvailableAboveTargetHealthAfterDepositing()`
5. `healthAfterDeposit()`
6. `healthAfterWithdrawal()`
7. `positionHealth()`
8. `healthComputation()` (static function)

### Phase 2: Position Management Tests

#### Test 5: Position Struct Interface
**What to test**: Position struct relay methods
**Note**: Health bounds methods (`setTargetHealth`, etc.) are no-ops in Position struct
**What works**:
- `getBalances()`
- `getAvailableBalance()`
- `deposit()` / `depositAndPush()`
- `withdraw()` / `withdrawAndPull()`
- `createSink()` / `createSinkWithOptions()`
- `createSource()` / `createSourceWithOptions()`

#### Test 6: Enhanced Sink/Source
**What to test**: DFB integration
**How to test**:
- Create PositionSink with `pushToDrawDownSink` option
- Create PositionSource with `pullFromTopUpSource` option
- Verify they implement DFB interfaces correctly

### Phase 3: Integration Tests

#### Test 7: Oracle Integration
**What to test**: Price oracle affects health calculations
**How to test**:
- Use `DummyPriceOracle`
- Change prices
- Verify health calculations reflect price changes

#### Test 8: Multi-Token Positions
**What to test**: Positions with multiple token types
**How to test**:
- Add multiple supported tokens to pool
- Deposit different tokens
- Verify health calculations across tokens

## Test Limitations

### Cannot Test Directly (Internal Functions):
1. `rebalancePosition()` - Internal function
2. `queuePositionForUpdateIfNecessary()` - Internal function
3. `processPositionUpdates()` - Internal function
4. `asyncUpdatePosition()` - Internal function
5. Health bounds in InternalPosition - No public getters

### Workarounds:
- Test effects indirectly through public APIs
- Verify behavior through position state changes
- Use health calculation functions to infer internal state

## Implementation Notes

### Creating Position with Capability:
```cadence
// Cannot create Position struct directly in tests
// Position requires Capability<auth(EPosition) &Pool>
// This is an internal capability not exposed publicly
```

### Testing Queued Deposits:
```cadence
// Cannot directly access position.queuedDeposits
// Can only verify through:
// 1. Checking immediate deposit amount is limited
// 2. Observing gradual deposit increases over time
```

### Testing Rebalancing:
```cadence
// Cannot call rebalancePosition() directly
// Rebalancing happens automatically during:
// 1. depositAndPush() operations
// 2. Async updates (internal)
```

## Test Coverage Goals

### High Priority (Must Test):
- ✅ All 8 health calculation functions
- ✅ Deposit rate limiting behavior
- ✅ Enhanced deposit/withdraw functions
- ✅ Oracle price integration
- ✅ Multi-token support

### Medium Priority (Should Test):
- ✅ Sink/Source creation and usage
- ✅ Available balance calculations
- ✅ Position details retrieval
- ✅ Balance sheet calculations

### Low Priority (Nice to Have):
- ⚠️ Async update behavior (hard to test)
- ⚠️ Rebalancing triggers (internal)
- ⚠️ Queue processing (internal)

## Success Criteria

1. **All public APIs tested**: Every public function has at least one test
2. **Core behaviors verified**: Rate limiting, health calculations work correctly
3. **Integration validated**: Oracle prices affect calculations properly
4. **Edge cases covered**: Zero balances, max values, empty positions
5. **No regressions**: Existing functionality still works

## Conclusion

While we cannot test every internal mechanism directly, we can verify that all restored features work correctly through their public interfaces. The test suite should focus on observable behavior rather than internal implementation details. 