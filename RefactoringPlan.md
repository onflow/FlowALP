# AlpenFlow Refactoring Plan

## Issue 1: FlowVault Type Conflict

### Problem
The AlpenFlow contract currently implements its own `FlowVault` resource type which will conflict with the real FlowToken.Vault when integrating with Tidal contracts and transactions.

### Current Implementation
```cadence
// In AlpenFlow.cdc
access(all) resource FlowVault: FungibleToken.Vault {
    access(all) var balance: UFix64
    // ... implementation details
}
```

### Solution
1. Remove the `FlowVault` implementation from AlpenFlow.cdc
2. Import the real FlowToken contract
3. Update all references to use `FlowToken.Vault` instead of `FlowVault`
4. Update test files to use Test.serviceAccount() for FLOW tokens

### Implementation Steps

#### Step 1: Update AlpenFlow.cdc
- Remove the `FlowVault` resource definition (lines ~40-56)
- Add import: `import "FlowToken"`
- Replace all `FlowVault` references with `FlowToken.Vault`
- Update the `createTestVault` function to use FlowToken

#### Step 2: Update Test Files
- Remove `createTestVault` function
- Use `Test.serviceAccount()` to mint FLOW tokens
- Update all test files to use proper FlowToken vaults

#### Step 3: Update Test Helper
- Create a helper function that mints FLOW from service account
- Ensure all tests use this standardized approach

## Issue 2: PR Workflow for Future Changes

### Current State
- All changes have been pushed directly to main branch
- No PR review process for feedback

### Recommended Workflow
1. Create feature branches for new work
2. Open PRs targeting main branch
3. Use inline comments for specific feedback
4. Merge after review approval

### Implementation
```bash
# For future changes:
git checkout -b feature/remove-flowvault-implementation
# Make changes
git push origin feature/remove-flowvault-implementation
# Open PR on GitHub for review
```

## Priority
1. **Immediate**: Set up feature branch workflow for this refactoring
2. **High**: Remove FlowVault implementation to prevent type conflicts
3. **Medium**: Update all tests to use proper FLOW token minting

## Testing Strategy
1. Ensure all existing tests still pass after refactoring
2. Verify integration with real FlowToken contract works
3. Test that FLOW transfers work correctly in test environment

## Timeline
- Create feature branch: Immediate
- Implement FlowVault removal: 1-2 hours
- Update all tests: 2-3 hours
- Testing and verification: 1 hour
- PR review cycle: As needed 