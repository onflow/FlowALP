# User Balance Displayed in the EARN Product

**Status**: Proposed  
**Date**: 2026-02-19  
**Authors**: Alex Hentschel, Dete Shirley  
**Component**: Flow EARN 

**Creation**: Alex H with AI assistance (fully fact-checked)

### References
[Slack discussion](https://flow-foundation.slack.com/archives/C08QF29F7TK/p1771567751505249?thread_ts=1771355840.068079&cid=C08QF29F7TK) and 
[Q&A meeting notes from Feb 19, 2026](https://docs.google.com/document/d/1jGj-ypjLO1Uo2ZPL4xtRyRlMAdbW4THozGc2i3z6TAc/edit?tab=t.buc00sqsnehk)

## Context

Flow's Automated Lending Protocol [ALP] and Flow EARN (the yield-source management component built on top of ALP) need to display position balances to users. At maturity, ALP will support positions with **multiple collateral types and multiple borrowed assets**. However, a single EARN position only supports a **single collateral type and single yield type** for the time being. Users can still utilize EARN with different supported collaterals by opening independent positions, each of which is managed separately.

The question is: what balance should EARN display to the user, and how should the underlying price be determined?

## Decision

### 1. Balance formula for EARN

The balance displayed to a user in Flow EARN is:

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

For `CP`, use the **spot price** of the collateral token. This was confirmed in the Q&A meeting (2026-02-19) and aligns with how most conventional brokerages and crypto trading platforms report asset values.

The displayed balance must be clearly labeled to indicate it is an **estimate based on spot prices** and does not account for slippage that would occur if the user unwound their position.

### 3. Scope: EARN Product only

This formula and display logic apply **only to Flow's EARN product**. ALP itself does not need to present converted balances to users for the time being.

### 4. ALP: anticipate multi-asset positions

Engineers should **anticipate** (but not yet fully implement) support for positions with multiple collateral types and multiple borrowed assets in ALP's design.

_Outlook on ALP reporting user balances:_
0. ALP reporting user balances is likely not needed at all _for the initial version of FCM_, as users interact with the EARN product rather than ALP directly.
1. The most universal approach for ALP would be to report a user's position as a list of their collateral and debt amounts in their native tokens, without converting to a single denomination. This is simpler to implement and avoids the complexities of multi-asset valuation.
2. If unified representations are desired for ALP in the future, they can be built on top of the aforementioned per-token report.



## Alternatives Considered, Rationale for Chosen Approach & Conclusions

### Using spot price for user balances in EARN (chosen approach)

1. **Simplicity.** Spot price is the simplest computation to implement. Dete's guidance was to implement whichever approach is easiest, as long as it is clearly communicated to the user.
2. **User familiarity.** Spot-price-based balances match the convention used by most existing finance platforms and crypto exchanges. Users expect this presentation.
3. **Transparency over precision.** Rather than showing an "exit value" (which would be pessimistic for large positions due to slippage), showing spot price with a clear disclaimer is more straightforward. Users with large positions would otherwise see an unnecessarily deflated balance.
4. **Single-asset simplification.** Since EARN only supports one collateral type and one yield type per position, the formula is straightforward — no multi-asset weighting or proportional distribution is required.

### Alternative: Exit-value-based pricing

Instead of spot price, compute `CP` as a quote for fully unwinding the user's EARN position (i.e., accounting for slippage).

- **Pro:** More accurate reflection of what the user would actually receive upon exit.
- **Con:** Pessimistic for large positions — slippage from a hypothetical full unwind in a single transaction would understate the position's value.
- **Con:** More complex to compute (requires simulating a full unwind against the AMM).
- **Con:** Departs from the convention used by most finance platforms.

If this approach were chosen, the displayed value should be labeled as "current exit value" to set correct user expectations.


### Conclusion

Either approach would be acceptable per Dete's guidance, as long as the methodology is clearly documented and communicated to the user. The prevalent market standard is to use spot prices, and there is no reason to deviate from that established convention in EARN.

In addition, the following practical and product considerations further support the spot price approach: Slippage depends heavily on market conditions and the user's strategy for unwinding (e.g., breaking into multiple transactions vs. a single transaction). Estimating the exit value of larger positions — which would incur significant slippage when unwound — is therefore highly challenging. If we assumed the position was unwound in a single trade, we would report potentially over-pessimistic values, hurting the user's perception of FCM's performance. In practice, users with large positions generally intend to unwind gradually to minimize slippage losses, so the spot price probably better reflects the exit value they are planning for. For small positions where slippage is negligible, the spot price directly provides a reasonable estimate of the position's value.




## Implementation Notes

- **Clear labeling:** The UI and documentation must state that the EARN balance is an estimate based on spot prices and does not account for slippage.
- **Negative balances:** Handle the case where `CD > YV` gracefully — the second term becomes negative, reducing the displayed balance below `CT`.
- **Future multi-asset support:** ALP's data model should be designed to accommodate multiple collateral and debt types per position, even though EARN will only use single-type positions for the time being.
- **CP availability:** An open question was raised during the Q&A: whether the current price of collateral denominated in MOET (`CP`) is reliably available on every block. This needs to be confirmed during implementation.

## User Impact

- **EARN users** will see a single consolidated balance denominated in their collateral token, providing a clear view of their net position value.
- **Large position holders** should be aware that the displayed balance is based on spot prices and may not reflect the exact amount receivable upon full withdrawal (due to slippage).
