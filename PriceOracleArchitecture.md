# Price Oracle Architecture

This document describes the price oracle design for the ALP.
How multiple sources are combined into a single trusted oracle interface, and how routing and aggregation are split across two contracts.

## Overview

The protocol depends on a **single trusted oracle** that returns either a valid price or `nil` when the price should not be used (e.g. liquidation or rebalancing should be skipped). The protocol does **not** validate prices; it only consumes the oracle’s result.

Two contracts implement this design:

| Contract | Role |
|----------|------|
| **FlowPriceOracleAggregatorv1** | Combines multiple price sources for **one** market (e.g. several FLOW/USDC oracles). Returns a price only when sources agree within spread tolerance and short-term gradient is stable. |
| **FlowPriceOracleRouterv1** | Exposes **one** `DeFiActions.PriceOracle` that routes by token type. Each token has its own oracle; typically each oracle is an aggregator. |

Typical usage: create one **aggregator** per market (same token pair, multiple sources), then register each aggregator in a **router** under the corresponding token type. The protocol then uses the router as its single oracle.

That makes total sense. Direct mutations in production are essentially "testing in prod," which is a recipe for disaster. Forcing a full replacement ensures a clean audit trail and clear governance.

Here is a refined version that incorporates those specific points:

### Immutable Configuration

The **Aggregator** and **Router** are immutable by design to eliminate the risks associated with live production changes.

* **Eliminates "Testing in Prod":** Because parameters cannot be modified in place, you avoid the risk of breaking a live oracle. Instead, new configurations can be fully tested as a separate instance before deployment.
* **Centralized Governance:** Changes can only be made by updating the oracle reference on the **ALP**. This makes it explicitly clear who holds governance authority over the system.
* **Timelock Compatibility:** Since updates require a fresh deployment, it is easy to implement an "Escape Period" (Timelock). This introduces a mandatory delay before a new oracle address takes effect, giving users time to react or exit before the change goes live.
* **Transparent Auditing:** Every change is recorded on-chain via the `PriceOracleUpdated` event, ensuring all shifts in logic or parameters are visible and expected.

## FlowPriceOracleAggregatorv1

One aggregated oracle per “market” (e.g. FLOW in USDC). Multiple underlying oracles, single unit of account, fixed tolerances.
- **Price flow:**
  1. Collect prices from all oracles for the requested token.
  2. If any oracle returns nil → emit `PriceNotAvailable`, return nil.
  3. Compute min/max; if spread > `maxSpread` → emit `PriceNotWithinSpreadTolerance`, return nil.
  4. Compute aggregated price (trimmed mean: drop min and max, average the rest).
  5. Check short-term stability: compare current price to recent history; if any gradient > `maxGradient` → emit `PriceNotStable`, return nil.
  6. Otherwise return the aggregated price.
- **History:** An array of `(price, timestamp)` is maintained. Updates are permissionless via `tryAddPriceToHistory()` (idempotent); A FlowCron job should be created to call this regularly.
Additionally every call to price() will also attempt to store the price in the history.

## Aggregate price (trimmed mean)

To avoid the complexity of a full median, the aggregator uses a **trimmed mean**: remove the single maximum and single minimum, then average the rest. This reduces the impact of a single outlier or “oracle jitter.”

- With <2 prices: mean
- With 3+ prices: `(sum - min - max) / (count - 2)`.

## Oracle spread (coherence)

A **pessimistic relative spread** is used: the distance between the most extreme oracle prices relative to the **minimum** price.

$$
\text{Spread} = \frac{Price_{\max} - Price_{\min}}{Price_{\min}}
$$

The price set is **coherent** only if:

$$
\text{isCoherent} =
\begin{cases}
\text{true}  & \text{if } \frac{Price_{\max} - Price_{\min}}{Price_{\min}} \le maxSpread \\
\text{false} & \text{otherwise}
\end{cases}
$$

## Short-term gradient (stability)

The aggregator keeps an array of the last **n** aggregated prices (with timestamps), respecting `priceHistoryInterval` and `maxPriceHistoryAge`.

For each historical point (i), the **gradient to the current price** is the relative change per unit time (scaled for “per minute”):

$$
\text{Gradient}_{i} = \frac{|Price_{\text{current}} - Price_{i}|}{\min(Price_{\text{current}}, Price_{i}) \cdot (t_{\text{current}} - t_{i})} \times \text{6000}
$$

The current price is **stable** only if **every** such gradient (from each valid history entry to the current price) is at or below the configured `maxGradient`. If **any** gradient is above the threshold, the aggregator emits `PriceNotStable(gradient)` and returns nil.

$$
\text{isStable} =
\begin{cases}
\text{true}  & \text{if } \text{Gradient}_{i} \le \text{maxGradient} \text{ for all } i \\
\text{false} & \text{otherwise (price invalid)}
\end{cases}
$$

Implementationally, entries older than `maxPriceHistoryAge` are ignored; same-block timestamps are treated with a minimum time delta of 1 to allow small jitter within the same block.

---

## FlowPriceOracleRouterv1

Single oracle interface that routes by **token type**. Each token type maps to an oracle. This makes it easy to combine different aggrigators without the need to supply different kinds of thresholds for individual token types.
