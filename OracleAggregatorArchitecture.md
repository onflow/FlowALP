# OracleAggregator

## Requirements

- The lending protocol (ALP / FCM) depends on a single trusted oracle interface that returns either a valid price or nil if the price should not be trusted.
- The lending protocol does not contain any logic for validating prices and simply consumes the output of the trusted oracle.
- The oracle aggregator combines multiple price sources such as on-chain DEX prices and off-chain price feeds.
- A price is considered usable only if the sources are reasonably aligned within a configurable tolerance and recent price changes are not anomalous.
- If sources diverge beyond tolerance or show suspicious short-term volatility, the aggregator returns nil and the protocol skips actions like liquidation or rebalancing.
- Governance is responsible for configuring which sources are used and what tolerances apply, not the lending protocol itself.
- This separation is intentional so the lending protocol remains reusable and does not encode assumptions about specific oracle implementations.

---
# Design draft: The following sections outline ideas that are still being designed. 

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
## Short-term volatility

The oracle maintains a ring buffer of the last `n` aggregated prices with timestamps,
respecting `minTimeDelta` and `maxTimeDelta`.
Prices are collected on calls to `price()`.
If multiple updates occur within the same `minTimeDelta`, only the most recent price is retained.

The pessimistic relative price move is:

$$
\text{Move} = \frac{Price_{max} - Price_{min}}{Price_{min}}
$$

The price history is considered **Stable** only if the move is below the configured
maximum allowed move.

$$
\text{isStable} =
\begin{cases}
\text{true} & \text{if } \text{Move} \le \text{maxMove} \\
\text{false} & \text{otherwise}
\end{cases}
$$
