# Test Update Summary for Restored Features

## Overview

This document summarizes all the test updates needed to properly test the features restored from Dieter's AlpenFlow implementation.

## Key Changes in Restored Code

### 1. Pool Creation Now Requires Oracle
```cadence
// OLD - No longer works
let pool <- TidalProtocol.createPool(
    defaultToken: Type<@MockVault>(),
    defaultTokenThreshold: 100.0  // This parameter removed
)

// NEW - Required pattern
let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<@MockVault>())
let pool <- TidalProtocol.createPool(
    defaultToken: Type<@MockVault>(),
    priceOracle: oracle
)
```

### 2. Enhanced Deposit/Withdraw Functions
```cadence
// Basic functions (existing)
pool.deposit(pid: pid, funds: <-vault)
pool.withdraw(pid: pid, type: Type<@MockVault>(), amount: 100.0)

// Enhanced functions (restored)
pool.depositAndPush(pid: pid, from: <-vault, pushToDrawDownSink: false)
pool.withdrawAndPull(pid: pid, type: type, amount: amount, pullFromTopUpSource: false)
```

### 3. Position Struct Limitations
```cadence
// Cannot create Position struct in tests
// Requires Capability<auth(EPosition) &Pool> which is internal

// Health bounds methods are no-ops
position.setTargetHealth(1.5)  // Does nothing
position.getTargetHealth()      // Always returns 0.0
```

## Tests That Need Updates

### 1. core_vault_test.cdc
**Current Issues**:
- Uses old pool creation pattern
- Doesn't test enhanced deposit/withdraw functions
- Doesn't test rate limiting

**Updates Needed**:
- Add oracle to pool creation
- Test `depositAndPush()` with rate limiting
- Test `withdrawAndPull()` with source integration

### 2. position_health_test.cdc
**Current Issues**:
- May not test all 8 health calculation functions
- Doesn't test oracle price impact on health

**Updates Needed**:
- Add tests for all health calculation functions
- Test health changes with oracle price updates
- Test multi-token health calculations

### 3. interest_mechanics_test.cdc
**Current Issues**:
- May access internal state directly
- Doesn't test automatic time updates via tokenState()

**Updates Needed**:
- Remove direct globalLedger access
- Verify interest updates happen automatically

### 4. token_state_test.cdc
**Current Issues**:
- May try to access TokenState directly
- Doesn't test deposit rate limiting

**Updates Needed**:
- Test rate limiting behavior
- Verify automatic state updates

### 5. reserve_management_test.cdc
**Current Issues**:
- May not test multi-token positions properly
- Doesn't test with oracle price changes

**Updates Needed**:
- Add multi-token tests with different prices
- Test reserve calculations with price changes

## New Test Files Needed

### 1. deposit_rate_limiting_test.cdc
```cadence
// Test 5% deposit cap
// Test queued deposits behavior
// Test gradual deposit processing
```

### 2. health_functions_test.cdc
```cadence
// Test all 8 health calculation functions
// Test with various collateral/debt scenarios
// Test edge cases (zero debt, max values)
```

### 3. oracle_integration_test.cdc
```cadence
// Test price changes affect health
// Test multi-token pricing
// Test DummyPriceOracle functionality
```

### 4. enhanced_apis_test.cdc
```cadence
// Test depositAndPush with sink
// Test withdrawAndPull with source
// Test availableBalance with source
```

## Common Test Patterns

### Setting Up Pool with Oracle
```cadence
access(all) fun setupPoolWithOracle(): @TidalProtocol.Pool {
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // Add token support with rate limiting
    pool.addSupportedToken(
        tokenType: Type<String>(),
        collateralFactor: 1.0,
        borrowFactor: 1.0,
        interestCurve: TidalProtocol.SimpleInterestCurve(),
        depositRate: 1000000.0,      // High rate = no limiting
        depositCapacityCap: 1000000.0
    )
    
    return <- pool
}
```

### Testing Rate Limiting
```cadence
access(all) fun testRateLimiting() {
    let pool <- setupPoolWithLowRate()
    let pid = pool.createPosition()
    
    // Note: Can't deposit actual vaults without proper implementation
    // Can only verify structure and calculations
    
    // Test deposit limit calculation
    let details = pool.getPositionDetails(pid: pid)
    Test.assertEqual(0, details.balances.length)
    
    destroy pool
}
```

### Testing Health Functions
```cadence
access(all) fun testAllHealthFunctions() {
    let pool <- setupPoolWithOracle()
    let pid = pool.createPosition()
    
    // Test each function with empty position
    let required = pool.fundsRequiredForTargetHealth(pid: pid, type: Type<String>(), targetHealth: 2.0)
    Test.assertEqual(0.0, required)
    
    // ... test other 7 functions ...
    
    destroy pool
}
```

## Testing Limitations

### Cannot Test Directly:
1. **Actual vault deposits/withdrawals** - Need proper vault implementation
2. **Internal position state** - queuedDeposits, health bounds
3. **Rebalancing triggers** - Internal function
4. **Async updates** - Internal function

### Can Test:
1. **All public API functions** - Health calculations, etc.
2. **Pool configuration** - Token support, oracle setup
3. **Position creation** - ID generation
4. **Calculation logic** - Health formulas, interest rates

## Priority Order

### Phase 1: Fix Existing Tests
1. Update all pool creation to use oracle
2. Remove any direct internal state access
3. Add missing health function tests

### Phase 2: Add New Test Coverage
1. Create deposit_rate_limiting_test.cdc
2. Create health_functions_test.cdc
3. Create oracle_integration_test.cdc
4. Create enhanced_apis_test.cdc

### Phase 3: Integration Tests
1. Update FlowToken integration test
2. Update MOET integration test
3. Add multi-token integration tests

## Success Metrics

- All tests pass with restored code
- 100% coverage of public APIs
- No access to internal state
- Clear documentation of what can't be tested
- Examples of each restored feature working 