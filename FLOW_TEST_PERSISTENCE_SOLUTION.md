# Flow Test Framework Contract Persistence Solution

## Problem
The Flow test framework error "cannot overwrite existing contract" occurs because contracts persist between test runs. This is a known limitation where the test environment doesn't fully reset between tests.

## Root Cause
When running multiple test files together (`flow test`), each test file's `setup()` function tries to deploy contracts. If a contract was already deployed by a previous test file, the deployment fails with "cannot overwrite existing contract".

## Solutions Applied

### 1. Removed Incorrect Test.reset() Usage
The failing tests (`pool_creation_workflow_test.cdc` and `reserve_withdrawal_test.cdc`) were using `Test.reset()` incorrectly:
- They took a snapshot AFTER deploying contracts
- When `Test.reset(to: snapshot)` was called, it reset to that point, but the contracts deployed by the test framework were no longer available
- This caused "cannot find declaration" errors

**Fix**: Removed `Test.reset()` from tests that don't need it. These tests run first and don't need to reset state.

### 2. Use Test.reset() Correctly (for tests that need it)
For tests that DO need to reset state between test cases:

```cadence
access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()
    // Take snapshot AFTER all contracts are deployed
    snapshot = getCurrentBlockHeight()
}

access(all)
fun testFirstTest() {
    Test.reset(to: snapshot) // Reset to clean state
    // Your test logic here
}
```

## Current Status
- Individual test files now pass when run separately
- Running all tests together still has conflicts due to different test files trying to deploy the same contracts

## Workarounds for Running All Tests

### 1. Run Tests Individually
```bash
flow test ./cadence/tests/pool_creation_workflow_test.cdc
flow test ./cadence/tests/reserve_withdrawal_test.cdc
# ... etc
```

### 2. Clear Cache Between Full Test Runs
```bash
rm -rf ~/.flow
flow test --cover
```

### 3. Use a Test Runner Script
Create a script that runs each test file separately:
```bash
#!/bin/bash
for test in cadence/tests/*.cdc; do
    echo "Running $test..."
    flow test "$test"
done
```

## Long-term Solution
The ideal solution would be to refactor the test suite to:
1. Have a single shared setup that deploys all contracts once
2. Use snapshots and Test.reset() consistently across all tests
3. Or separate tests that need different contract deployments into different test suites

## Implementation Notes
- The FlowALP codebase already uses the snapshot pattern correctly in several test files:
  - `platform_integration_test.cdc`
  - `position_lifecycle_happy_test.cdc`
  - `rebalance_overcollateralised_test.cdc`
  - `rebalance_undercollateralised_test.cdc`
  - `token_governance_addition_test.cdc`

- The two files that were failing have been fixed:
  - `pool_creation_workflow_test.cdc` - removed unnecessary Test.reset()
  - `reserve_withdrawal_test.cdc` - removed unnecessary Test.reset()

## References
- [Cadence Testing Framework Documentation](https://cadence-lang.org/docs/testing-framework)
- [Flow Forum: Major Uplift for Cadence Testing Framework](https://forum.flow.com/t/major-uplift-for-cadence-testing-framework/5232) 
