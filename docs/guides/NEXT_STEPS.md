# Next Steps for Test Updates

## Summary

All tests need to be updated to use oracle-based pool creation. The old `createTestPool(defaultTokenThreshold:)` pattern no longer works because pools now require a PriceOracle parameter.

## Current State

- ✅ Documentation complete (TEST_UPDATE_PLAN.md, TEST_IMPLEMENTATION_GUIDE.md)
- ✅ Test helper placeholders added to guide implementation
- ❌ All test files still use old pool creation pattern
- ❌ No tests currently handle oracle or addSupportedToken requirements

## Implementation Steps

### 1. Fix test_helpers.cdc
Replace placeholder functions with actual implementations:
```cadence
// Example implementation
access(all) fun createTestPoolWithOracle(): @TidalProtocol.Pool {
    let oracle = TidalProtocol.DummyPriceOracle(
        defaultToken: Type<@MockVault>()
    )
    oracle.setPrice(token: Type<@MockVault>(), price: 1.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<@MockVault>(),
        priceOracle: oracle
    )
    
    pool.addSupportedToken(
        tokenType: Type<@MockVault>(),
        collateralFactor: 1.0,
        borrowFactor: 1.0,
        interestCurve: TidalProtocol.SimpleInterestCurve(),
        depositRate: 1000000.0,
        depositCapacityCap: 1000000.0
    )
    
    return <- pool
}
```

### 2. Update Each Test File
Replace all occurrences of:
```cadence
// OLD
var pool <- createTestPool(defaultTokenThreshold: 1.0)

// NEW
var pool <- createTestPoolWithOracle()
```

### 3. Add Oracle Price Manipulation Tests
Create new test cases for oracle functionality:
- Price changes affect health
- Different tokens have different prices
- Risk parameters work correctly

### 4. Handle Empty Vault Issue
Add workarounds in tests that might trigger empty vault creation:
- Leave tiny amounts when withdrawing
- Or expect failures appropriately

### 5. Test Rate Limiting
Add new tests for deposit rate limiting (5% cap)

## Files to Update (in order)

1. **test_helpers.cdc** - Implement real functions
2. **simple_test.cdc** - Already working ✅
3. **core_vault_test.cdc** - Update pool creation
4. **interest_mechanics_test.cdc** - Update pool creation
5. **position_health_test.cdc** - Update + add oracle tests
6. **token_state_test.cdc** - Update pool creation
7. **reserve_management_test.cdc** - Update pool creation
8. **access_control_test.cdc** - Update pool creation
9. **edge_cases_test.cdc** - Update + handle empty vault
10. **flowtoken_integration_test.cdc** - Real token integration
11. **moet_integration_test.cdc** - Stablecoin integration
12. **governance_test.cdc** - If needed
13. **attack_vector_tests.cdc** - Update for rate limiting
14. **fuzzy_testing_comprehensive.cdc** - Complex updates

## Success Metrics

- [ ] All 22 basic tests passing
- [ ] No compilation errors
- [ ] Oracle functionality tested
- [ ] Rate limiting tested
- [ ] Empty vault issue handled
- [ ] Coverage > 85%

## Recommended Approach

1. Start with test_helpers.cdc implementation
2. Update one simple test file completely
3. Verify it passes
4. Apply same pattern to other files
5. Add new oracle-specific tests
6. Fix intensive tests last

The key is that EVERY pool creation must now:
1. Create an oracle
2. Set token prices
3. Create pool with oracle
4. Call addSupportedToken with all parameters

This is a significant change but follows a consistent pattern across all tests. 