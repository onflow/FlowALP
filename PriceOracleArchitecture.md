# Price Oracle Architecture

This document describes the price oracle design for the ALP.
How multiple sources are combined into a single trusted oracle interface, and how routing and aggregation are split across two contracts.

## Overview

The protocol depends on a **single trusted oracle** that returns either a valid price or `nil` when the price should not be used (e.g. liquidation or rebalancing should be skipped). The protocol does **not** validate prices; it only consumes the oracle’s result.

Two contracts implement this design:

| Contract | Role |
|----------|------|
| **FlowPriceOracleAggregatorv1** | Combines multiple price sources for **one** market (e.g. several FLOW/USDC oracles). Returns a price only when sources agree within spread tolerance and short-term history is within `baseTolerance` + `driftExpansionRate` (stability). |
| **FlowPriceOracleRouterv1** | Exposes **one** `DeFiActions.PriceOracle` that routes by token type. Each token has its own oracle; typically each oracle is an aggregator. |

Typical usage: create one **aggregator** per market (same token pair, multiple sources), then register each aggregator in a **router** under the corresponding token type. The protocol then uses the router as its single oracle.

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
  5. Check short-term stability: compare current price to recent history; for each history entry the allowed relative difference is `baseTolerance + driftExpansionRate * deltaTMinutes`; if any relative difference exceeds that → emit `PriceNotWithinHistoryTolerance`, return nil.
  6. Otherwise return the aggregated price.
- **History:** An array of `(price, timestamp)` is maintained. Updates are permissionless via `tryAddPriceToHistory()` (idempotent); A FlowCron job should be created to call this regularly.
Additionally every call to price() will also attempt to store the price in the history.

## Aggregate price (trimmed mean)

To avoid the complexity of a full median, the aggregator uses a **trimmed mean**: remove the single maximum and single minimum, then average the rest. This reduces the impact of a single outlier.

- With 1 oracle: that price.
- With 2 oracles: arithmetic mean.
- With 3+ oracles: trimmed mean `(sum - min - max) / (count - 2)`.

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

## Short-term stability (history tolerance)

The aggregator keeps an array of the last **n** aggregated prices (with timestamps), respecting `priceHistoryInterval` and `maxPriceHistoryAge`.

Stability is defined by two parameters:

- **baseTolerance** (n): fixed buffer to account for immediate market noise.
- **driftExpansionRate** (m): additional allowance per minute to account for natural price drift.

For each historical point (i), the **allowed relative difference** between the current price and the history price grows with time:

$$
\text{allowedRelativeDiff}_{i} = \text{baseTolerance} + \text{driftExpansionRate} \times \Delta t_{\text{minutes}}
$$

where Delta t_minutes is the time in minutes from the history entry to now. The **actual relative difference** is:

$$
\text{relativeDiff}_{i} = \frac{|Price_{\text{current}} - Price_{i}|}{\min(Price_{\text{current}}, Price_{i})}
$$

The current price is **stable** only if **every** such relative difference (from each valid history entry to the current price) is at or below the allowed tolerance for that entry. If **any** exceeds it, the aggregator emits `PriceNotWithinHistoryTolerance(relativeDiff, deltaTMinutes, maxAllowedRelativeDiff)` and returns nil.

$$
\text{isStable} =
\begin{cases}
\text{true}  & \text{if } \text{relativeDiff}_{i} \le \text{allowedRelativeDiff}_{i} \text{ for all } i \\
\text{false} & \text{otherwise (price invalid)}
\end{cases}
$$

Implementationally, entries older than `maxPriceHistoryAge` are ignored when evaluating stability.

**Parameter units:** `maxSpread`, `baseTolerance`, and `driftExpansionRate` are dimensionless relative values (e.g. `0.01` = 1%, `1.0` = 100%). All are bounded by the contract to ≤ 10000.0.

## FlowPriceOracleRouterv1

Single oracle interface that routes by **token type**. Each token type maps to an oracle. This makes it easy to combine different aggregators without the need to supply different kinds of thresholds for individual token types.

- **Price flow:** `price(ofToken)` looks up the oracle for that token type; if none is registered, returns `nil`. All oracles must share the same `unitOfAccount` (enforced at router creation).
- **Empty router:** If the oracle map is empty or a token type is not registered, `price(ofToken)` returns `nil`.
