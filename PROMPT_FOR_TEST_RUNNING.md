# Prompt: Running FlowALP Tests with New Approach

## Background
The FlowALP Cadence tests were failing with "cannot overwrite existing contract" errors due to Flow test framework limitations. We've implemented a solution.

## Your Task
When asked to run tests for FlowALP, follow this new approach:

### Primary Method: Use Test Runner Script
```bash
# This is the recommended way to run all tests
./run_tests.sh
```

This script automatically:
- Runs each test file individually
- Clears Flow cache between tests
- Avoids contract persistence issues

### Alternative: Run Individual Tests
If you need to run specific tests:
```bash
flow test ./cadence/tests/pool_creation_workflow_test.cdc
flow test ./cadence/tests/reserve_withdrawal_test.cdc
```

### What NOT to do
- Don't run `flow test` without arguments (it will fail due to contract conflicts)
- Don't add `Test.reset()` to tests unless you understand the snapshot pattern

## Key Changes Made
1. Removed incorrect `Test.reset()` calls from:
   - `pool_creation_workflow_test.cdc`
   - `reserve_withdrawal_test.cdc`

2. Created `run_tests.sh` script for reliable test execution

3. Added documentation files:
   - `FLOW_TEST_PERSISTENCE_SOLUTION.md` - explains the issue
   - `TEST_RUNNING_INSTRUCTIONS.md` - detailed guide

## Expected Behavior
- Individual tests should pass when run separately
- Some tests have known issues (MockOracle, MockFlowALPConsumer conflicts)
- The test runner script provides the most consistent results

## Example Output
When using the test runner script, you'll see:
```
📝 Running: cadence/tests/pool_creation_workflow_test.cdc
✅ PASSED: cadence/tests/pool_creation_workflow_test.cdc

📝 Running: cadence/tests/reserve_withdrawal_test.cdc
✅ PASSED: cadence/tests/reserve_withdrawal_test.cdc
```

Please use this approach when working with FlowALP tests to ensure consistent and reliable results.

## Verified Status (as of latest changes)
Tests confirmed to PASS individually:
- ✅ `pool_creation_workflow_test.cdc` - PASS: testPoolCreationSucceeds
- ✅ `reserve_withdrawal_test.cdc` - PASS: testReserveWithdrawalGovernanceControlled

These were the two tests we fixed by removing incorrect `Test.reset()` usage. 
