# Displayed to the User in `Earn` Product

**Status**: Proposed  
**Date**: 2026-02-19    
**Authors**: Alex Hentschel, Dete Shirley  
**Component**: Flow Earn 

### References
[Slack discussion](https://flow-foundation.slack.com/archives/C08QF29F7TK/p1771567751505249?thread_ts=1771355840.068079&cid=C08QF29F7TK) and 
[Q&A meeting notes from Feb 19, 2026](https://docs.google.com/document/d/1npAwIq1W-EU7S7c2sX17zMdZffu5mr06DD6krBkvTFo/edit?usp=sharing)

## Context

Flow's Automated Lending Protocol [ALP] and Flow Earn (the yield-source management component built on top of ALP) need to display position balances to users. At maturity, ALP will support positions with **multiple collateral types and multiple borrowed assets**. However, the current Flow Earn implementation only supports a **single collateral type and single yield type per position**.

The question is: what balance should Earn display to the user, and how should the underlying price be determined?

## Decision

### 1. Balance formula for Earn

The balance displayed to a user in Flow Earn is:

```
Balance = CT + (YV - CD) / CP
```

Where:
- **CT** = Count of collateral tokens held
- **YV** = Value of yield tokens (denominated in MOET)
- **CD** = Current debt amount (denominated in MOET)
- **CP** = Current price of collateral tokens (denominated in MOET)

Note: `CD` can exceed `YV`, making the second term negative. The result represents the user's net position denominated in collateral tokens.

### 2. Price source: spot price

For `CP`, use the **spot price** of the collateral token. This is the simpler approach and aligns with how most brokerages and crypto trading platforms report asset values.

The displayed balance must be clearly labeled to indicate it is an **estimate based on spot prices** and does not account for slippage that would occur if the user unwound their position.

### 3. Scope: Earn only

This formula and display logic apply **only to Flow Earn**. ALP itself does not need to display converted balances to users at this time — ALP balances would simply show deposited and borrowed amounts without conversion.

### 4. ALP: anticipate multi-asset positions

Engineers should **anticipate** (but not yet fully implement) support for positions with multiple collateral types and multiple borrowed assets in ALP's design. Since Earn only deals with a single collateral and single yield type per position, no proportional distribution of `(YV - CD)` across different asset types is needed now.

## Rationale

1. **Simplicity.** Spot price is the simplest computation to implement. Dete's guidance was to implement whichever approach is easiest, as long as it is clearly communicated to the user.
2. **User familiarity.** Spot-price-based balances match the convention used by most existing finance platforms and crypto exchanges. Users expect this presentation.
3. **Transparency over precision.** Rather than showing an "exit value" (which would be pessimistic for large positions due to slippage), showing spot price with a clear disclaimer is more straightforward. Users with large positions would otherwise see an unnecessarily deflated balance.
4. **Single-asset simplification.** Since Earn only supports one collateral type and one yield type per position, the formula is straightforward — no multi-asset weighting or proportional distribution is required.

## Alternatives Considered

### Exit-value-based pricing

Instead of spot price, compute `CP` as a quote for fully unwinding the user's Earn position (i.e., accounting for slippage).

- **Pro:** More accurate reflection of what the user would actually receive upon exit.
- **Con:** Pessimistic for large positions — slippage from a hypothetical full unwind in a single transaction would understate the position's value.
- **Con:** More complex to compute (requires simulating a full unwind against the AMM).
- **Con:** Departs from the convention used by most finance platforms.

If this approach were chosen, the displayed value should be labeled as "current exit value" to set correct user expectations.

Either approach is acceptable per Dete's guidance, as long as the methodology is clearly documented and communicated to the user.

## Implementation Notes

- **Clear labeling:** The UI and documentation must state that the Earn balance is an estimate based on spot prices and does not account for slippage.
- **Negative balances:** Handle the case where `CD > YV` gracefully — the second term becomes negative, reducing the displayed balance below `CT`.
- **Future multi-asset support:** ALP's data model should be designed to accommodate multiple collateral and debt types per position, even though Earn will only use single-type positions initially.

## User Impact

- **Earn users** will see a single consolidated balance denominated in their collateral token, providing a clear view of their net position value.
- **Large position holders** should be aware that the displayed balance is based on spot prices and may not reflect the exact amount receivable upon full withdrawal (due to slippage).
