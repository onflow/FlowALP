# AlpenFlow Test Troubleshooting Notes

## Issue Summary

We're experiencing issues with running tests that interact with resources in the AlpenFlow contract. While we can deploy the contract successfully, and simple tests that just import the contract work fine, tests that actually try to call resource-related functions always fail with:

```
error: failed to load contract: f8d6e0586b0a20c7.AlpenFlow
```

## Observed Patterns

1. **Working Tests:**
   - Tests that just import the contract (simple_test.cdc)
   - Tests that access type information (access_test.cdc)
   - Tests with simple function calls (function_test.cdc)

2. **Failing Tests:**
   - Tests that call `createTestPool()` (core_vault_test.cdc)
   - Tests that call `createTestVault()` (mini_core_test.cdc)
   - Tests that call `scaledBalanceToTrueBalance()` (scaledBalance_test.cdc)

## Steps Taken

1. **Access Controls:**
   - Changed all utility functions from `access(self)` to `access(all)`
   - Verified that helper functions are accessible by looking at the contract code

2. **Reference Fixes:**
   - Fixed `createTestPoolWithBalance` to use `AlpenFlow.` instead of `self.` when calling other helper functions

3. **Environment Setup:**
   - Restarted the emulator and cleared its state multiple times
   - Redeployed the contract multiple times
   - Updated `flow.json` to include an explicit emulator alias

4. **Diagnostics:**
   - Created a simple test that only imports the contract (passes)
   - Created a test that accesses type information only (passes)
   - Created a test that tries to use utility functions (fails)
   - Created the simplest possible test that tries to create a resource (fails)

## Current Hypothesis

We believe there might be an issue with:

1. How the test runner resolves resource-related functionality in the contract
2. How authorization is handled for contract functions in the test environment
3. Possible incompatibilities between the Flow emulator, CLI, and test runner versions
4. Potential issues with resource references in tests

## Next Steps (For Flow Engineers)

1. Examine the contract code to confirm access controls are correct
2. Check if there are known issues with testing resource creation in Cadence contracts
3. Verify if the specific version of Flow CLI or emulator has any reported bugs
4. Provide guidance on the correct way to test resource creation and management

## Flow/Cadence Versions

- Flow CLI: Pre-2.2.14 (update warning appears in logs)
- Flow Emulator: Version used with above CLI
- Cadence Version: As bundled with the above tools 