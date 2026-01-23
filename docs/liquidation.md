# FlowCreditMarket Liquidation Mechanism

## Overview

FlowCreditMarket uses a two-tier system to protect against insolvent positions:
1. **Automatic rebalancing** (first line of defense) - proactively manages position health
2. **Liquidation** (second line of defense) - resolves unhealthy positions when rebalancing is insufficient

Liquidations should be relatively rare events, invoked only when automatic rebalancing fails to maintain position solvency.

## Key Concepts

### Effective Collateral

The effective collateral represents a risk-adjusted value of deposited collateral, denominated in USD:

```
Ce = (Nc)(Pc)(Fc)
```

Where:
- `Ce` = Effective Collateral ($)
- `Nc` = Number of collateral tokens
- `Pc` = Collateral token price ($/token)
- `Fc` = Collateral factor (0-1, representing risk discount)

The collateral factor applies a discount to the market value, creating a safety buffer. For example, Fc=0.8 means only 80% of the collateral's market value counts toward the position's borrowing capacity.

### Effective Debt

The effective debt represents a risk-adjusted value of borrowed funds, denominated in USD:

```
De = (Nd)(Pd) / Fd
```

Where:
- `De` = Effective Debt ($)
- `Nd` = Number of debt tokens
- `Pd` = Debt token price ($/token)
- `Fd` = Borrow factor (0-1, representing risk discount)

The borrow factor inflates the debt value, creating additional safety margin. For example, Fd=0.9 means debt is treated as if it's worth 1/0.9 = ~11% more than its market value for health calculations.

### Health Factor

The health factor is a measure of position solvency:

```
HF = Ce / De
```

- **HF > 1.0**: Healthy position (over-collateralized)
- **HF = 1.0**: Break-even point
- **HF < 1.0**: Unhealthy position (under-collateralized, eligible for liquidation)
- **HF = ∞**: No debt outstanding

## Automatic Rebalancing: First Line of Defense

Before liquidation becomes necessary, positions can configure automatic rebalancing via DeFiActions sources and sinks:

- **Top-up Source**: When a position falls below its `minHealth` threshold, the Pool automatically pulls funds from the configured source to restore health
- **Draw-down Sink**: When a position exceeds its `maxHealth` threshold, the Pool automatically pushes excess collateral to the configured sink

Positions that enable automatic rebalancing can avoid liquidation entirely, as the system proactively maintains their health within the configured range. **Note:** The specific `minHealth` threshold for rebalancing is distinct from the global liquidation trigger (HF < 1.0).

Automatic rebalancing may fail to maintain a position's health for several reasons:
- The position has not provided a top-up source
- The position has provided a top-up source, but it does not have sufficient withdrawable balance
- Collateral or debt prices moved too quickly for the periodic rebalancing process (implemented by Scheduled Transactions) to balance the position in time. (Rebalancing occurs on a best-effort basis.)

## Manual Liquidation: Second Line of Defense

When a position's health factor falls below 1.0 and cannot be restored through rebalancing, it becomes eligible for liquidation via the `manualLiquidation` function.

NOTE: This mechanism will be extended to include automated liquidation in the future (see `## Future Extensions` below)

### Liquidation Conditions

A liquidation is accepted if all of the following are met:

1. **Pre-liquidation health**: Position HF < 1.0
2. **Post-liquidation health**: After the liquidation, HF ≤ `liquidationTargetHF` (currently 1.05)
3. **Amount constraints**: Cannot repay more debt or seize more collateral than exists in the position
4. **Price constraints**: Liquidator must offer a better price than could be obtained from a DEX

**Important**: A liquidation need not _improve_ the health factor. If a position is insolvent (e.g., due to a large price drop), liquidations that reduce the position size but leave HF < 1.0 are still accepted. This prevents accumulation of bad debt in the case that the depreciating asset continues to depreciate.

### Liquidation Mechanics

The liquidator specifies:
- The debt token type to repay
- The collateral token type to seize
- The amount of collateral to seize
- A vault containing the repayment amount

The protocol:
1. Validates the position is unhealthy (HF < 1.0)
2. Calculates post-liquidation health using effective collateral/debt formulas
3. Ensures post-liquidation HF ≤ 1.05 (prevents over-liquidation)
4. Ensures the liquidation offers a better price than what is available from a DEX
5. Ensures the DEX price and Oracle price do not diverge by too large a margin
6. Deposits repayment to reserves and withdraws seized collateral
7. Returns seized collateral to the liquidator

## Incentive Mechanism

### Short Term

**No explicit incentive is provided.** The Flow Foundation will perform liquidations manually as needed during the initial deployment period. Since FCM is operated by Flow Foundation, any cost of liquidation is offset by the benefit of protecting the protocol's solvency.

### Long Term

Liquidations will occur automatically via DEX integration. The protocol will:
1. Automatically liquidate unhealthy positions by trading collateral for debt tokens on integrated DEXs
2. Accept manual liquidation offers from external parties **only if they provide a better price than the DEX**

In this model, no explicit incentive (liquidation bonus) is necessary. Liquidators can profit by:
- Accessing larger liquidity pools than the on-chain DEX
- Taking advantage of temporary DEX price inefficiencies
- Avoiding DEX slippage on large trades

The liquidator's incentive is implicit: they can acquire the position's collateral at a better rate than the DEX would offer, while the protocol benefits from receiving a better price than it could achieve through automated DEX liquidation.

## Future Extensions

### Automatic DEX Liquidation

A future update will add infrastructure for automatic liquidation via DEX (https://github.com/onflow/FlowCreditMarket/issues/97).

### Liquidation Controls

The protocol includes governance-controlled parameters:

- **Liquidation pause**: Can pause/unpause liquidations with a configurable warm-up period (currently 300 seconds)
- **Target health factor**: Configurable maximum post-liquidation health (currently 1.05)
- **DEX configuration**: `SwapperProvider` representing the configured DEX providers, oracle deviation tolerance
