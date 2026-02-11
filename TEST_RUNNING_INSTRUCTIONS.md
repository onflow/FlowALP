# Test Running Instructions for FlowALPv1

## Context
The Flow test framework has a known limitation where contracts persist between test runs, causing "cannot overwrite existing contract" errors. We've implemented fixes and workarounds to address this issue.

## Changes Made
1. **Fixed test files** that were incorrectly using `Test.reset()`:
   - `cadence/tests/pool_creation_workflow_test.cdc` - removed unnecessary reset
   - `cadence/tests/reserve_withdrawal_test.cdc` - removed unnecessary reset

2. **Created test runner script** (`run_tests.sh`) that handles contract persistence issues

3. **Added documentation** (`FLOW_TEST_PERSISTENCE_SOLUTION.md`) explaining the root cause

## How to Run Tests

### Option 1: Use the Test Runner Script (Recommended)
```bash
# Make sure the script is executable
chmod +x run_tests.sh

# Run all tests individually with automatic cache clearing
./run_tests.sh
```

This script:
- Runs each test file separately to avoid contract conflicts
- Clears Flow cache (`~/.flow`) before each test
- Shows clear pass/fail status for each test
- Returns appropriate exit codes for CI/CD

### Option 2: Run Tests Individually
```bash
# Run specific test files one at a time
flow test ./cadence/tests/pool_creation_workflow_test.cdc
flow test ./cadence/tests/reserve_withdrawal_test.cdc
flow test ./cadence/tests/platform_integration_test.cdc
# ... etc
```

### Option 3: Clear Cache and Run All (Less Reliable)
```bash
# Clear Flow cache first
rm -rf ~/.flow

# Then run all tests
flow test --cover
```
Note: This may still fail due to contract deployment conflicts between test files.

## Expected Results

### Tests that should PASS individually:
- ✅ `pool_creation_workflow_test.cdc`
- ✅ `reserve_withdrawal_test.cdc`
- ✅ `test_helpers.cdc` (no actual tests, just helpers)

### Tests with known issues:
- ⚠️ `platform_integration_test.cdc` - has some failing test cases due to MockOracle issues
- ⚠️ `token_governance_addition_test.cdc` - contract import issues

## Understanding Test.reset() Usage

The snapshot pattern should be used like this:
```cadence
access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()
    // Take snapshot AFTER contracts are deployed
    snapshot = getCurrentBlockHeight()
}

access(all)
fun testExample() {
    // Reset to snapshot before running test
    Test.reset(to: snapshot)
    // ... test logic ...
}
```

**Important**: Only use `Test.reset()` when you need to reset blockchain state between multiple test functions in the same file. Don't use it for the first test or when there's only one test.

## Troubleshooting

### "cannot overwrite existing contract" error
- Use the test runner script or run tests individually
- Clear Flow cache: `rm -rf ~/.flow`

### "cannot find declaration" error after Test.reset()
- Make sure snapshot is taken AFTER contract deployment
- Don't use Test.reset() unless necessary

### Tests pass individually but fail together
- This is expected due to contract persistence
- Use the test runner script for consistent results

## For CI/CD Integration
Use the test runner script:
```yaml
- name: Run Cadence Tests
  run: |
    chmod +x run_tests.sh
    ./run_tests.sh
```

The script returns exit code 0 if all tests pass, 1 if any fail. 
