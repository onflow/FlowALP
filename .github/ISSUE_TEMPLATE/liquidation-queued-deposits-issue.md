# Queued Deposits in Liquidation Health Calculations

## Summary

Should queued deposits be considered when calculating position health for liquidation purposes? This discussion explores the trade-offs between protecting users from over-liquidation during rate limiting versus maintaining safety guarantees in the liquidation mechanism.

## Context

FlowCreditMarket implements deposit rate limiting with a queue mechanism for excess deposits. Currently, position health calculations for liquidations only consider the current position makeup and do not account for queued deposits that haven't been processed yet.

Related files:
- `cadence/contracts/FlowCreditMarket.cdc` - Position health calculations (`healthFactor` at line 1028)
- `docs/deposit_capacity_mechanism.md` - Deposit queue documentation
- `LIQUIDATION_MECHANISM_DESIGN.md` - Current liquidation design

## Problem Statement

Users may have sufficient funds queued to make their position healthy but are temporarily rate-limited. In a black swan event or during high network congestion, these users could be liquidated even though they have the capital to maintain a healthy position.

## Proposed Solution (Jon)

**Implement differential health calculations based on context:**

### For Rebalancing
- Use **current position makeup only**
- Queued deposits are NOT considered
- Standard health calculation as currently implemented

### For Liquidations
- Use **current position + queued deposits**
- Include queued deposit amounts when calculating effective collateral
- More conservative approach to avoid over-liquidating users

**Rationale:**
- Don't penalize users who have funds available but are rate-limited
- Conservative approach for rare black swan scenarios
- Maintains user trust during network congestion or deposit queue backlogs

## Concerns (Jordan)

### Safety Reasoning
Much of the liquidation safety reasoning relies on:
- How quickly price can move per unit time
- How frequently FCM/liquidators can make adjustments

### Unbounded Latency
- The deposit queue is **theoretically unbounded**
- Time until queued deposits are available is also **unbounded**
- This introduces an extra source of latency into the liquidation process
- Could compromise safety guarantees if queued deposits take too long to process

### Need for Further Analysis
- Impact on liquidation timing and safety margins
- Edge cases where queued deposits never process
- Interaction with oracle price updates and market volatility

## Unique Context

FlowCreditMarket is one of the only protocols with deposit rate limiting via queues. Most other protocols use:
- Simple caps on deposits per asset
- No queuing mechanism
- Immediate rejection of excess deposits

This makes it harder to find precedent or established patterns for this specific problem.

## Open Questions

1. **Bounds on Queue Processing**: Can we establish guaranteed upper bounds on queue processing time?
2. **Safety Analysis**: How does including queued deposits affect the mathematical safety proofs?
3. **Complexity Trade-off**: Is the added complexity worth the user protection benefits?
4. **Partial Solution**: Could we include queued deposits up to some bounded amount or time window?
5. **Alternative Approaches**: Are there other ways to protect rate-limited users from liquidation?

## Implementation Considerations

If proceeding with this feature:

1. **Create separate health calculation functions:**
   ```cadence
   healthFactorForRebalancing(view: PositionView): UFix128
   healthFactorForLiquidation(view: PositionView, includeQueuedDeposits: Bool): UFix128
   ```

2. **Update liquidation eligibility checks** in:
   - `quoteLiquidation()`
   - `liquidateRepayForSeize()`
   - `liquidateViaDex()`
   - `autoLiquidate()`

3. **Add queued deposit calculation** to `PositionView` or create extended view

4. **Update tests** to cover:
   - Liquidation with queued deposits preventing liquidation
   - Rebalancing ignoring queued deposits
   - Edge cases with large queued amounts

5. **Document safety assumptions** around queue processing bounds

## Next Steps

- [ ] Jon to analyze bounded queue processing scenarios
- [ ] Jordan to model safety implications with unbounded queues
- [ ] Evaluate if complexity is justified by benefits
- [ ] Consider time-boxed or amount-limited variants
- [ ] Get input from Lionel on Cadence implementation details

## Related Work

- PR #111 - Documentation and TODO updates
- `LIQUIDATION_MECHANISM_DESIGN.md` - Phase 1 liquidation design
- `deposit_capacity_mechanism.md` - Rate limiting documentation

## Labels

`enhancement`, `liquidation`, `safety`, `needs-discussion`

## Priority

Medium - Not blocking current liquidation implementation, but important for user protection in edge cases
