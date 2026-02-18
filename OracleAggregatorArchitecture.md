# OracleAggregator

## Requirements

- The lending protocol (ALP / FCM) depends on a single trusted oracle interface that returns either a valid price or nil if the price should not be trusted.
- The lending protocol does not contain any logic for validating prices and simply consumes the output of the trusted oracle.
- The oracle aggregator combines multiple price sources such as on-chain DEX prices and off-chain price feeds.
- A price is considered usable only if the sources are reasonably aligned within a configurable tolerance and recent price changes are not anomalous.
- If sources diverge beyond tolerance or the short-term gradient exceeds the configured threshold, the aggregator returns nil and the protocol skips actions like liquidation or rebalancing.
- Governance is responsible for configuring which sources are used and what tolerances apply, not the lending protocol itself.
- This separation is intentional so the lending protocol remains reusable and does not encode assumptions about specific oracle implementations.

---
# Design draft: The following sections outline ideas that are still being designed.

Intentionally immutable to avoid bugs, through changing configs in production without testing.
If oracles change there should be an OracelChange event emitted from the ALP contract.

## Aggregate price

To avoid the complexity of calculating a median, we instead use a trimmed mean: removing the maximum and minimum values to protect against "oracle jitter."

## Oracle spread

A **Pessimistic Relative Spread** calculation is used. This measures the distance between the most extreme values in the oracles ($Price_{max}$ and $Price_{min}$) relative to the lowest value.

$$
\text{Spread} = \frac{Price_{max} - Price_{min}}{Price_{min}}
$$

A price set is considered **Coherent** only if the calculated spread is within the configured tolerance ($\tau$):

$$
\text{isCoherent} =
\begin{cases}
\text{true} & \text{if } \left( \frac{Price_{max} - Price_{min}}{Price_{min}} \right) \le \tau \\
\text{false} & \text{otherwise}
\end{cases}
$$

## Short-term gradient

The oracle maintains a ring buffer of the last **n** aggregated prices with timestamps, respecting `minTimeDelta` and `maxTimeDelta`.

For each historical point $i$, the **gradient to the current price** is the relative change per unit time:

$$
\text{Gradient}_{i} = \frac{Price_{current} - Price_{i}}{Price_{i} \cdot (t_{current} - t_{i})}
$$

The current price is considered **Stable** only if **every** such gradient (from each of the n historical points to the current price) is at or below the configured threshold. If **any** gradient is above the threshold, the current price is **invalid** and the aggregator returns nil.

$$
\text{isStable} =
\begin{cases}
\text{true}  & \text{if } \text{Gradient}_{i} \le \text{gradientThreshold} \text{ for all } i \\
\text{false} & \text{otherwise (price invalid)}
\end{cases}
$$
