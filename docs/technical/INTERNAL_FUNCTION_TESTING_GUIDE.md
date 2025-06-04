# Testing Internal Functions in Cadence

## Overview

Internal functions in Cadence cannot be directly tested from outside the contract. However, there are several patterns and approaches to ensure they are properly tested.

## Testing Philosophy

### 1. Black-box vs White-box Testing

**Black-box Testing (Recommended Primary Approach)**
- Test only public interfaces
- Focus on observable behavior
- Ensures tests remain valid even if internal implementation changes
- More maintainable and less brittle

**White-box Testing (For Critical Logic)**
- Test internal functions when they contain complex business logic
- Useful for security-critical calculations
- Provides deeper coverage for edge cases

### 2. When to Test Internal Functions

Test internal functions when they:
- Contain complex business logic (e.g., health calculations)
- Handle critical state transitions
- Perform security-sensitive operations
- Have multiple edge cases that need verification

## Testing Patterns for Cadence

### Pattern 1: Test Through Public APIs (Recommended)

The most maintainable approach is to test internal functions through their effects on public functions:

```cadence
// Instead of testing tokenState() directly, test its effects
access(all) fun testAutomaticStateUpdates() {
    let pool <- createPool()
    let pid = pool.createPosition()
    
    // Deposit triggers tokenState() internally
    pool.deposit(pid: pid, funds: <-vault)
    
    // Verify state was updated (interest accrued, etc.)
    let details = pool.getPositionDetails(pid: pid)
    Test.assert(details.lastUpdate == getCurrentBlock().timestamp)
}
```

### Pattern 2: Test Harness Contract (For Development Only)

Create a test-only contract that exposes internal functions:

```cadence
// ONLY FOR TESTING - DO NOT DEPLOY
access(all) contract TidalProtocolTestHarness {
    // Expose internal functions for testing
    access(all) fun testTokenState(pool: &Pool) {
        // Call internal function and return results
    }
}
```

**Warning**: This approach has limitations in Cadence:
- Cannot access private contract state
- Cannot call access(contract) functions
- Only useful for testing pure logic

### Pattern 3: Property-Based Testing

Test invariants and properties that should hold regardless of internal implementation:

```cadence
access(all) fun testHealthInvariants() {
    // Test that health calculations maintain invariants
    let pool <- createPool()
    let pid = pool.createPosition()
    
    // Property: Empty position should have specific health
    Test.assertEqual(1.0, pool.positionHealth(pid: pid))
    
    // Property: Health should never be negative
    // Test various scenarios...
}
```

### Pattern 4: Integration Testing

Test complete workflows that exercise internal functions:

```cadence
access(all) fun testDepositWithRateLimiting() {
    let pool <- createPoolWithLowRate()
    let pid = pool.createPosition()
    
    // This workflow tests:
    // - tokenState() updates
    // - Rate limiting logic
    // - Queue processing
    // - Health recalculation
    
    // Large deposit triggers internal rate limiting
    let largeAmount = 1000000.0
    pool.depositAndPush(pid: pid, from: <-largeVault, pushToDrawDownSink: false)
    
    // Verify only 5% was deposited immediately
    let details = pool.getPositionDetails(pid: pid)
    Test.assert(details.totalDeposited <= largeAmount * 0.05)
}
```

## Best Practices

### 1. Focus on Observable Behavior
```cadence
// Good: Test what users can observe
access(all) fun testPositionHealthAfterDeposit() {
    let healthBefore = pool.positionHealth(pid: pid)
    pool.deposit(pid: pid, funds: <-vault)
    let healthAfter = pool.positionHealth(pid: pid)
    Test.assert(healthAfter > healthBefore)
}

// Avoid: Testing internal state directly
// This is not possible in Cadence anyway
```

### 2. Use Descriptive Test Names
```cadence
// Good: Describes the scenario and expected outcome
access(all) fun testLargeDepositIsQueuedWhenExceedsRateLimit() { }

// Less clear
access(all) fun testDeposit() { }
```

### 3. Test Edge Cases Through Public APIs
```cadence
access(all) fun testHealthCalculationEdgeCases() {
    // Test zero collateral
    let health1 = pool.healthComputation(
        effectiveCollateral: 0.0,
        effectiveDebt: 100.0
    )
    Test.assertEqual(0.0, health1)
    
    // Test max values
    let health2 = pool.healthComputation(
        effectiveCollateral: UFix64.max / 2.0,
        effectiveDebt: 1.0
    )
    Test.assert(health2 > 0.0)
}
```

### 4. Document What Cannot Be Tested
```cadence
// Document testing limitations
// Cannot test directly:
// - rebalancePosition() - internal function
// - queuedDeposits state - internal to InternalPosition
// - asyncUpdatePosition() - internal async function
//
// These are tested indirectly through:
// - Deposit/withdraw operations
// - Health calculations over time
// - Position state changes
```

## Specific Patterns for TidalProtocol

### Testing Rate Limiting
```cadence
access(all) fun testDepositRateLimiting() {
    // Setup pool with specific rate limit
    let pool <- createPool()
    pool.addSupportedToken(
        tokenType: Type<MockToken>(),
        depositRate: 1000.0,  // Low rate to trigger limiting
        depositCapacityCap: 10000.0
    )
    
    // Test that large deposits are limited
    // Even though we can't see queuedDeposits directly
}
```

### Testing Health Functions
```cadence
access(all) fun testAllHealthCalculationScenarios() {
    // Create comprehensive test matrix
    let scenarios = [
        // [collateral, debt, expectedHealth]
        [0.0, 0.0, 0.0],      // Empty position
        [100.0, 50.0, 2.0],   // Healthy position
        [50.0, 100.0, 0.5],   // Undercollateralized
        // ... more scenarios
    ]
    
    for scenario in scenarios {
        let health = pool.healthComputation(
            effectiveCollateral: scenario[0],
            effectiveDebt: scenario[1]
        )
        Test.assertEqual(scenario[2], health)
    }
}
```

## Limitations in Cadence

### What Cannot Be Tested
1. **Private Functions**: Not visible to any external code
2. **Internal State**: Cannot directly access contract's internal variables
3. **access(contract) Functions**: Only callable within the contract
4. **Resource Internal State**: Cannot inspect resource's private fields

### Workarounds
1. **Test Effects**: Focus on observable state changes
2. **Use Events**: Emit events from internal functions for testing
3. **Test Invariants**: Verify properties that should always hold
4. **Integration Tests**: Test complete user workflows

## Conclusion

While Cadence doesn't allow direct testing of internal functions like some other languages, you can achieve comprehensive test coverage by:

1. Testing through public APIs
2. Focusing on observable behavior
3. Using integration tests for complex workflows
4. Testing invariants and properties
5. Documenting what cannot be tested directly

The key is to ensure that all critical business logic is exercised through your tests, even if you cannot directly call internal functions. This approach leads to more maintainable tests that are less likely to break when internal implementation details change. 