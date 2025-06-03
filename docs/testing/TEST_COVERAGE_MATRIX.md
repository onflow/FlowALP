# Test Coverage Matrix for TidalProtocol

## Restored Features Test Coverage

### 1. Core Infrastructure Tests

| Feature | Test Needed | Test File | Status | Notes |
|---------|-------------|-----------|---------|-------|
| tokenState() automatic updates | ✅ | restored_features_test.cdc | ✅ Implemented | Tests through observable effects |
| InternalPosition queued deposits | ✅ | restored_features_test.cdc | ✅ Implemented | Tests rate limiting behavior |
| Deposit rate limiting (5% cap) | ✅ | restored_features_test.cdc | ✅ Implemented | Tests capacity calculations |
| Position update queue | ✅ | restored_features_test.cdc | ✅ Implemented | Tests through effects |

### 2. Health Management Tests

| Feature | Test Needed | Test File | Status | Notes |
|---------|-------------|-----------|---------|-------|
| fundsRequiredForTargetHealth() | ✅ | restored_features_test.cdc | ✅ Implemented | All 8 functions tested |
| fundsRequiredForTargetHealthAfterWithdrawing() | ✅ | restored_features_test.cdc | ✅ Implemented | |
| fundsAvailableAboveTargetHealth() | ✅ | restored_features_test.cdc | ✅ Implemented | |
| fundsAvailableAboveTargetHealthAfterDepositing() | ✅ | restored_features_test.cdc | ✅ Implemented | |
| healthAfterDeposit() | ✅ | restored_features_test.cdc | ✅ Implemented | |
| healthAfterWithdrawal() | ✅ | restored_features_test.cdc | ✅ Implemented | |
| positionHealth() | ✅ | position_health_test.cdc + restored_features_test.cdc | ✅ Implemented | |
| healthComputation() | ✅ | restored_features_test.cdc | ✅ Implemented | Static function |
| Health bounds (min/target/max) | ✅ | restored_features_test.cdc | ✅ Implemented | Tests no-op behavior |
| Rebalancing logic | ✅ | restored_features_test.cdc | ⚠️ Partial | Cannot test internal function |

### 3. Enhanced APIs Tests

| Feature | Test Needed | Test File | Status | Notes |
|---------|-------------|-----------|---------|-------|
| depositAndPush() | ✅ | - | ❌ Missing | Need to create enhanced_apis_test.cdc |
| withdrawAndPull() | ✅ | - | ❌ Missing | Need to create enhanced_apis_test.cdc |
| availableBalance() with source | ✅ | restored_features_test.cdc | ✅ Implemented | |
| Position struct methods | ✅ | restored_features_test.cdc | ✅ Implemented | Tests interface |
| Sink/Source creation | ✅ | - | ❌ Missing | Need DFB integration tests |

### 4. Oracle Integration Tests

| Feature | Test Needed | Test File | Status | Notes |
|---------|-------------|-----------|---------|-------|
| DummyPriceOracle | ✅ | restored_features_test.cdc | ✅ Implemented | Basic functionality |
| Price changes affect health | ✅ | restored_features_test.cdc | ⚠️ Partial | Need more scenarios |
| Multi-token oracle pricing | ✅ | - | ❌ Missing | Need multi-token tests |
| Oracle in pool creation | ✅ | Multiple files | ✅ Implemented | All pools use oracle |

## Existing Tests That Need Updates

### Tests Requiring Oracle Updates

| Test File | Update Needed | Status | Notes |
|-----------|---------------|---------|-------|
| core_vault_test.cdc | Add oracle to pool creation | ✅ Updated | Uses createTestPoolWithOracle() |
| position_health_test.cdc | Add oracle, test all 8 functions | ❌ Needs Update | Missing oracle, only tests 3 functions |
| interest_mechanics_test.cdc | Remove internal state access | ❌ Needs Review | May access globalLedger |
| token_state_test.cdc | Test rate limiting | ❌ Needs Update | Missing rate limit tests |
| reserve_management_test.cdc | Add multi-token tests | ❌ Needs Update | Single token only |

### Integration Tests Status

| Test File | Purpose | Status | Updates Needed |
|-----------|---------|---------|----------------|
| flowtoken_integration_test.cdc | FlowToken integration | ⚠️ Partial | Add enhanced APIs |
| moet_integration_test.cdc | MOET integration | ⚠️ Partial | Add enhanced APIs |
| governance_integration_test.cdc | Governance features | ✅ OK | No updates needed |
| attack_vector_tests.cdc | Security tests | ❌ Needs Update | Add rate limiting attacks |

## New Test Files Needed

### Priority 1: Core Functionality
1. **enhanced_apis_test.cdc**
   - Test depositAndPush() with sink options
   - Test withdrawAndPull() with source options
   - Test DFB interface compliance

2. **multi_token_test.cdc**
   - Test positions with multiple tokens
   - Test oracle pricing for different tokens
   - Test health calculations across tokens

3. **rate_limiting_edge_cases_test.cdc**
   - Test exact 5% limit
   - Test queue processing over time
   - Test multiple deposits in sequence

### Priority 2: Advanced Features
4. **sink_source_integration_test.cdc**
   - Test PositionSink with drawdown
   - Test PositionSource with top-up
   - Test DFB composability

5. **oracle_advanced_test.cdc**
   - Test price volatility scenarios
   - Test oracle failures/edge cases
   - Test price manipulation resistance

### Priority 3: Comprehensive Coverage
6. **position_lifecycle_test.cdc**
   - Test complete position lifecycle
   - Test all state transitions
   - Test edge cases

7. **performance_stress_test.cdc**
   - Test with many positions
   - Test with many tokens
   - Test rate limiting under load

## Test Coverage Summary

### Current Coverage
- ✅ **Core Infrastructure**: 100% of testable features
- ✅ **Health Functions**: 8/8 functions tested
- ⚠️ **Enhanced APIs**: 40% (missing depositAndPush, withdrawAndPull)
- ✅ **Oracle Integration**: Basic coverage complete
- ❌ **Multi-token**: 0% (not tested)
- ⚠️ **Integration Tests**: Need updates for enhanced APIs

### Overall Test Status
- **Total Features**: 25
- **Fully Tested**: 15 (60%)
- **Partially Tested**: 5 (20%)
- **Not Tested**: 5 (20%)

### Next Steps Priority
1. Create enhanced_apis_test.cdc
2. Update existing tests to use oracle
3. Create multi_token_test.cdc
4. Update attack_vector_tests.cdc for rate limiting
5. Create sink_source_integration_test.cdc 