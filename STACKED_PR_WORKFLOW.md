# Stacked PR Workflow

## Overview
Creating PR #2 that depends on PR #1, allowing parallel review but sequential merging.

## Method 1: Stacked PRs (Recommended)
Create the second PR based on the first PR's branch instead of main.

```bash
# Start from the contracts branch (not main!)
git checkout feature/contracts-restoration

# Create new branch for tests/docs from contracts branch
git checkout -b feature/tests-and-docs

# Get all tests, transactions, scripts, and docs from original feature branch
git checkout fix/update-tests-for-complete-restoration -- cadence/tests/
git checkout fix/update-tests-for-complete-restoration -- cadence/transactions/
git checkout fix/update-tests-for-complete-restoration -- cadence/scripts/
git checkout fix/update-tests-for-complete-restoration -- docs/

# Update README with the full version
git checkout fix/update-tests-for-complete-restoration -- README.md

# Commit
git add .
git commit -m "feat: Add comprehensive test suite and documentation

- 141 passing tests (90.96% coverage)
- Test helpers and utilities
- Transaction examples
- Organized documentation in docs/ folder
- Integration guides for FlowToken and MOET

This PR depends on #8 and should be merged after it."

# Push
git push origin feature/tests-and-docs

# Create PR targeting the FIRST PR's branch (not main!)
gh pr create \
  --title "feat: Add comprehensive test suite and documentation" \
  --body "Depends on #8. This will be automatically updated to target main once #8 is merged." \
  --base feature/contracts-restoration \
  --head feature/tests-and-docs
```

## Method 2: Draft PR
Create as draft and convert to ready after first PR merges.

```bash
# Create from main but mark as draft
gh pr create --draft --title "..." --base main
```

## Method 3: Dependency Labels
Create PR with clear dependency notes and labels.

## Benefits of Stacked PRs

1. **Clear Dependency**: GitHub shows "This branch has conflicts that must be resolved" until base is merged
2. **Accurate Diff**: Shows only test/doc changes, not contract changes
3. **Auto-Update**: When PR #1 merges, PR #2 automatically updates to target main
4. **Parallel Review**: Both can be reviewed simultaneously
5. **Enforced Order**: Can't accidentally merge out of order

## What Reviewers See

### On PR #2:
```
Comparing feature/contracts-restoration...feature/tests-and-docs
- Shows ONLY test and documentation additions
- Much cleaner diff for review
```

### After PR #1 Merges:
```
Base automatically changed from feature/contracts-restoration to main
- PR #2 is now ready to merge
- No manual intervention needed
``` 