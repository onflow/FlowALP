# Auto-Borrowing Behavior Analysis & Proposal

## Summary of Findings

During testing, we discovered that TidalProtocol implements an **auto-borrowing** feature when positions are created with `pushToDrawDownSink=true`. This behavior is intentional and mathematically correct.

### Example Calculation
When depositing 1000 Flow tokens:
- Collateral Factor: 0.8 → Effective Collateral: 800
- Target Health: 1.3
- Auto-borrowed MOET: 800 ÷ 1.3 = **615.38**

This explains the balance value that Kan observed in the test output.

## Current Behavior

The `pushToDrawDownSink` parameter in `openPosition()` controls whether auto-borrowing occurs:

- **`true`**: Automatically borrows to achieve target health ratio (1.3)
- **`false`**: No auto-borrowing; position remains at maximum health

## Code Documentation Added

I've added explanatory comments to:
1. `rebalancePosition()` - Explaining the auto-borrowing logic
2. `depositAndPush()` - Noting when rebalancing triggers
3. `createPosition()` - Warning about auto-borrowing behavior

## Test Coverage

Created `auto_borrow_behavior_test.cdc` that verifies:
- Auto-borrowing calculates the correct amount (615.38 MOET)
- No borrowing occurs when `pushToDrawDownSink=false`

## Proposed Enhancement: `openPositionWithoutAutoBorrow()`

### Rationale
While `pushToDrawDownSink=false` works, it's not immediately obvious to users that this parameter controls auto-borrowing. A dedicated function would:

1. **Improve API clarity** - Function name clearly indicates no auto-borrowing
2. **Reduce confusion** - Users won't need to understand `pushToDrawDownSink` semantics
3. **Better defaults** - Conservative users get a safer default option

### Proposed Implementation
```cadence
access(all) fun openPositionWithoutAutoBorrow(
    collateral: @{FungibleToken.Vault},
    issuanceSink: {DeFiActions.Sink},
    repaymentSource: {DeFiActions.Source}?
): Position {
    // Always use pushToDrawDownSink=false to prevent auto-borrowing
    return self.openPosition(
        collateral: <-collateral,
        issuanceSink: issuanceSink,
        repaymentSource: repaymentSource,
        pushToDrawDownSink: false
    )
}
```

### Benefits
- **No breaking changes** - Existing code continues to work
- **Clearer intent** - Function name is self-documenting
- **Better UX** - Users can choose based on their needs:
  - `openPosition()` - Full control with parameters
  - `openPositionWithoutAutoBorrow()` - Simple, conservative option

## Recommendations

1. **Keep auto-borrowing as default** when `pushToDrawDownSink=true` for capital efficiency
2. **Add the convenience function** for users who prefer manual control
3. **Update documentation** to clearly explain both options
4. **Consider renaming** `pushToDrawDownSink` to `enableAutoBorrow` in future versions for clarity

## Questions for Reviewers

1. Should we implement the `openPositionWithoutAutoBorrow()` convenience function?
2. Is the current parameter name `pushToDrawDownSink` clear enough, or should we consider renaming?
3. Should the default behavior be auto-borrowing or no auto-borrowing?
4. Do we need additional safeguards or warnings for auto-borrowing?

## Next Steps

1. Await reviewer feedback on the proposal
2. Implement approved changes
3. Update documentation and examples
4. Consider adding more granular control over target health ratios per position 