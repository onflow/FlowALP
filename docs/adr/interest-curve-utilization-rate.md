# Interest Curve Utilization Rate Definition
**Status**: Proposed

**Date**: 2026-03-31

**Authors**: Jordan Schalm

**Component**: ALP

### References
- [Slack discussion in Flow Foundation](https://flow-foundation.slack.com/archives/C08QF29F7TK/p1773783670640229)
- [Automated Meeting Transcript & Notes](https://docs.google.com/document/d/1x5X8Dynlbs1IDO46NjckWnW3NaNw0nP9696W7MYQN60/edit?usp=sharing)

## Context

The protocol's interest curve requires a utilization rate to determine borrowing and lending rates. The current implementation computes utilization as `totalCredit / totalDebit`. This differs from the industry-standard approach (e.g. AAVE), and the way these values are computed is faulty in some circumstances, because they do not account for interest accumulation.

`totalDebt` and `totalCredit` are computed as the accumulation of inflows/outflows to/from debit/credit-direction positions. They are stored as absolute (not interest-adjusted) unsigned values, which can cause updates to the values to clamp to zero and become permanently inaccurate.

### Minimal Example
- User A deposits 100 units of X
- User B withdraws (borrows) 100 units of X -> totalDebit(X) = 100
- Suppose debit rate on X is 10%, and 1 year passes
- User B deposits 105 units of X -> totalDebit(X) = ceil(100 - 105, 0) = 0
  - User B still owes 5 units of X, but totalDebit(X) = 0

## Decision

### 1. Retain the interest curve utilization rate:

```
utilization = totalTrueCreditBalance / totalTrueDebitBalance
```

### 2. Re-define `totalTrueCreditBalance`/`totalTrueDebitBalance` to account for interest accrual.

Let's describe the definition wlog for `totalTrueDebitBalance`:
- Let `X` be some token
- Let `debitPositions(X)` be the set of positions which have a debit balance for token `X`
- Let `totalTrueDebitBalance(X)` be the sum of token X debit balances for all positions in `debitPositions(X)`

#### Timing of Interest and Utilization Updates

Interest and utilization are inter-related but computed **sequentially** to avoid circular dependency:

1. When a balance-mutating (deposits, withdrawals etc) operation occurs at time `t`, we first accrue interest using state from `t-1`
2. Then we apply the balance change using the updated interest index

Formally, for discrete time steps:
```
interestIndex[t]         = f(totalTrueBalance[t-1], interestIndex[t-1])
totalTrueBalance[t]      = g(totalTrueBalance[t-1], interestIndex[t], mutation)
```

This ensures interest accumulated between `t-1` and `t` is calculated based on the balances that existed during that period, **before** the current mutation is applied.


### 3. Change the protocol fee definition 

Prior to this ADR, protocol fees were computed as a percentage of estimated debit income, when extracted. Instead, we will compute protocol fees (insurance fee, stability fee) explicitly as the excess funds available in reserves.

```
cumulativeInterestSpread = totalTrueCreditBalance - totalTrueDebitBalance
protocolFee = reserveBalance - cumulativeInterestSpread
```

## Rationale

1. **Eliminates inaccuracy from clamping.** The current `totalCredit / totalDebit` approach can permanently accumulate inaccuracies from clamping. The proposed formula avoids this by accounting for interest accumulation.
2. **Clean fee handling.** Defining protocol fees in terms of actual reserve balances and credit/debit accounting values is easier to reason about.

## Related Changes

This ADR focuses on the utilization rate definition. The following related changes were discussed and should be addressed separately:

- **Protocol fee redefinition:** Change from a percentage of debit income to a basis-point spread between the debit rate and credit rate. In general, it would be good to consolidate how the fee definition is defined: currently it is a spread for fixed curves, and a percentage of debit income for other curves. (Possible overlap with https://github.com/onflow/FlowALP/pull/288).
- **Sanity checks:** Derive and enforce an invariant relating debit/credit interest indices, total true debit/credit balances, position true credit/debit balances, and protocol fees, either on-chain or off-chain.
- **Bad debt handling:** Currently manual; future work will automate liquidation using an insurance fund to cover shortfalls. 

## Implementation Notes

- Track `totalTrueCreditBalance`/`totalTrueDebitBalance` as **scaled values**, updating via scaled diffs on each position change.
- Add logic to convert scaled totals to true balances (scaled balance × interest index) for use in the utilization calculation.
- Protocol fee can be derived as: `reserveBalance + totalTrueDebitBalance - totalTrueCreditBalance`.
- Interest rate update logic incorrectly uses `totalDebitBalance`:
```
let debitIncome = self.totalDebitBalance * debitRate
```
