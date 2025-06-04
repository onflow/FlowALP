# Test Update Plan for 100% Restored TidalProtocol

## Overview

With the 100% restoration of Dieter's AlpenFlow implementation complete, all tests need to be updated to match the new code structure. This document outlines all required changes.

## Critical Changes Required

### 1. **Pool Creation Must Include Oracle**
All pool creation calls must be updated to include a price oracle parameter.

**Old Pattern:**
```cadence
let pool <- TidalProtocol.createPool(
    defaultToken: Type<@MockVault>(),
    defaultTokenThreshold: 100.0
)
```

**New Pattern:**
```cadence
// For tests - use DummyPriceOracle
let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<@MockVault>())
let pool <- TidalProtocol.createPool(
    defaultToken: Type<@MockVault>(),
    priceOracle: oracle
)

// Or use the helper function
let pool <- TidalProtocol.createTestPoolWithOracle(
    defaultToken: Type<@MockVault>()
)
```

### 2. **Add Supported Tokens with Risk Parameters**
When adding tokens to a pool, must include all required parameters.

**Required Parameters:**
```cadence
pool.addSupportedToken(
    tokenType: Type<@MOET.Vault>(),
    collateralFactor: 1.0,         // Required
    borrowFactor: 0.9,             // Required
    interestCurve: SimpleInterestCurve(),
    depositRate: 1000.0,           // Required for rate limiting
    depositCapacityCap: 1000000.0  // Required for rate limiting
)
```

### 3. **Set Oracle Prices**
After creating an oracle, must set prices for all tokens.

```cadence
oracle.setPrice(token: Type<@FlowToken.Vault>(), price: 5.0)
oracle.setPrice(token: Type<@MOET.Vault>(), price: 1.0)
```

### 4. **Handle Empty Vault Creation Issue**
Until the vault prototype storage is implemented, tests that expect empty vaults will fail.

**Temporary Workaround:**
- Avoid scenarios where withdrawal amount is 0
- Always ensure some balance remains
- Or handle the panic in tests

### 5. **Replace Direct globalLedger Access**
Any test that directly accesses globalLedger must be updated.

**Old:**
```cadence
let state = &pool.globalLedger[type]!
state.updateForTimeChange()
```

**New:**
```cadence
// This is now handled automatically by tokenState()
// No manual updates needed
```

## Test File Updates Required

### test_helpers.cdc
1. Update `createTestPool()` to use oracle
2. Update `createTestPoolWithBalance()` to use oracle
3. Add `createDummyOracle()` helper
4. Update MockVault to work with empty vault issue

### test_setup.cdc  
1. Update `createFlowTokenPool()` to use oracle
2. Add oracle setup in `deployAll()`
3. Update all pool creation examples

### All Test Files
1. Replace all `TidalProtocol.createPool()` calls
2. Add oracle price setup where needed
3. Update token addition with risk parameters
4. Remove any direct globalLedger access
5. Handle deposit rate limiting in tests

## Specific Test Patterns

### Basic Pool Setup
```cadence
access(all) fun setupTestPool(): @TidalProtocol.Pool {
    // Create oracle
    let oracle = TidalProtocol.DummyPriceOracle(
        defaultToken: Type<@MockVault>()
    )
    
    // Set initial prices
    oracle.setPrice(token: Type<@MockVault>(), price: 1.0)
    
    // Create pool
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<@MockVault>(),
        priceOracle: oracle
    )
    
    // Add supported token
    pool.addSupportedToken(
        tokenType: Type<@MockVault>(),
        collateralFactor: 1.0,
        borrowFactor: 1.0,
        interestCurve: TidalProtocol.SimpleInterestCurve(),
        depositRate: 1000000.0,  // High rate for tests
        depositCapacityCap: 1000000.0
    )
    
    return <- pool
}
```

### Testing with Multiple Tokens
```cadence
access(all) fun setupMultiTokenPool(): @TidalProtocol.Pool {
    let oracle = TidalProtocol.DummyPriceOracle(
        defaultToken: Type<@FlowToken.Vault>()
    )
    
    // Set different prices
    oracle.setPrice(token: Type<@FlowToken.Vault>(), price: 5.0)
    oracle.setPrice(token: Type<@MOET.Vault>(), price: 1.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<@FlowToken.Vault>(),
        priceOracle: oracle
    )
    
    // Add FLOW token
    pool.addSupportedToken(
        tokenType: Type<@FlowToken.Vault>(),
        collateralFactor: 0.8,
        borrowFactor: 0.8,
        interestCurve: TidalProtocol.SimpleInterestCurve(),
        depositRate: 1000.0,
        depositCapacityCap: 100000.0
    )
    
    // Add MOET stablecoin
    pool.addSupportedToken(
        tokenType: Type<@MOET.Vault>(),
        collateralFactor: 1.0,
        borrowFactor: 0.9,
        interestCurve: TidalProtocol.SimpleInterestCurve(),
        depositRate: 10000.0,
        depositCapacityCap: 1000000.0
    )
    
    return <- pool
}
```

### Testing Deposit Rate Limiting
```cadence
Test.test("Deposit rate limiting enforces 5% cap") {
    let pool <- setupTestPool()
    let poolRef = &pool as auth(TidalProtocol.EPosition) &TidalProtocol.Pool
    
    let pid = poolRef.createPosition()
    
    // Try to deposit large amount
    let largeVault <- createTestVault(balance: 100000.0)
    poolRef.deposit(pid: pid, funds: <-largeVault)
    
    // Check that only 5% was deposited
    let details = poolRef.getPositionDetails(pid: pid)
    Test.assert(details.balances[0].balance <= 5000.0)
    
    // Process async updates to deposit more
    poolRef.asyncUpdate()
    
    destroy pool
}
```

### Testing Price Changes
```cadence
Test.test("Health changes with oracle price updates") {
    let oracle = TidalProtocol.DummyPriceOracle(
        defaultToken: Type<@MockVault>()
    )
    oracle.setPrice(token: Type<@MockVault>(), price: 1.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<@MockVault>(),
        priceOracle: oracle
    )
    
    // Setup position with collateral
    // ... position setup code ...
    
    let healthBefore = poolRef.positionHealth(pid: pid)
    
    // Change price
    oracle.setPrice(token: Type<@MockVault>(), price: 0.5)
    
    let healthAfter = poolRef.positionHealth(pid: pid)
    Test.assert(healthAfter < healthBefore)
    
    destroy pool
}
```

## Migration Steps

1. **Update test_helpers.cdc first** - Core helpers used by all tests
2. **Update test_setup.cdc** - Setup functions
3. **Fix simple tests** - Start with basic functionality
4. **Fix complex tests** - Attack vectors, fuzzy testing
5. **Add new oracle tests** - Test price manipulation scenarios

## Expected Issues

1. **Empty vault panics** - Will occur in edge cases until fixed
2. **Missing parameters** - Old addSupportedToken calls missing new params
3. **Health calculations** - May differ due to oracle pricing
4. **Rate limiting** - Tests expecting immediate full deposits will fail

## Success Criteria

- [ ] All tests compile without errors
- [ ] All tests use oracle-based pools
- [ ] No direct globalLedger access
- [ ] Deposit rate limiting handled properly
- [ ] Empty vault issue documented in failing tests
- [ ] Test coverage remains > 85%

## Notes

- Keep MockVault for now until empty vault issue is resolved
- DummyPriceOracle is sufficient for most tests
- Production oracle tests can be added later
- Focus on functionality over optimization 