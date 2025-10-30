# FlowALP Auto-Borrowing Guide

## Overview

FlowALP includes an auto-borrowing feature that automatically optimizes your position's capital efficiency when creating a new position. This guide explains how it works and when to use it.

## What is Auto-Borrowing?

When you deposit collateral into FlowALP, the system can automatically borrow against that collateral to achieve a target health ratio. This maximizes capital efficiency by ensuring your position is neither too risky nor too conservative.

### Example
- You deposit 1000 Flow tokens as collateral
- Flow has a collateral factor of 0.8 (80% can be used as collateral)
- Effective collateral = 1000 × 0.8 = 800
- Target health ratio = 1.3
- The system automatically borrows 615.38 MOET (800 ÷ 1.3 ≈ 615.38)

## When to Use Auto-Borrowing

### Use `openPosition` with `pushToDrawDownSink=true` when:
- You want immediate capital efficiency
- You're comfortable with the protocol's target health ratio
- You want to receive borrowed funds immediately for other DeFi activities
- You're implementing automated strategies that require consistent leverage

### Example:
```cadence
let position = FlowALP.openPosition(
    collateral: <-myFlowVault,
    issuanceSink: mySink,
    repaymentSource: mySource,
    pushToDrawDownSink: true  // Enable auto-borrowing
)
```

## When NOT to Use Auto-Borrowing

### Use `pushToDrawDownSink=false` when:
- You want to manually control your borrowing amount
- You're depositing collateral but don't need to borrow yet
- You want to wait for better market conditions before borrowing
- You prefer a more conservative position initially

### Example:
```cadence
// Use openPosition with pushToDrawDownSink=false to disable auto-borrowing
let position = FlowALP.openPosition(
    collateral: <-myFlowVault,
    issuanceSink: mySink,
    repaymentSource: mySource,
    pushToDrawDownSink: false  // Disable auto-borrowing
)
```

### Proposed Enhancement
We're considering adding a convenience function `openPositionWithoutAutoBorrow()` that would make it even easier to create positions without auto-borrowing. This would provide a cleaner API for users who prefer manual control over their borrowing.

## Manual Borrowing After Position Creation

If you created a position without auto-borrowing, you can manually borrow later:

1. Monitor your position health
2. Decide how much to borrow based on your strategy
3. Use position management functions to borrow manually

## Key Concepts

- **Collateral Factor**: The percentage of your collateral's value that can be used for borrowing (e.g., 0.8 = 80%)
- **Target Health**: The ideal ratio of effective collateral to debt (default: 1.3)
- **Effective Collateral**: Your collateral value × collateral factor
- **Health Ratio**: Effective collateral ÷ debt (must stay above 1.0 to avoid liquidation)

## Best Practices

1. **Understand the Math**: With auto-borrowing, your initial debt = effective collateral ÷ target health
2. **Monitor Your Position**: Even with auto-borrowing, market conditions can change your health ratio
3. **Have a Repayment Plan**: Whether auto-borrowing or not, ensure you can manage the borrowed funds
4. **Test First**: Try both approaches with small amounts to understand the behavior

## Summary

Auto-borrowing is a powerful feature for capital efficiency, but it's not always the right choice. Choose based on your:
- Risk tolerance
- Investment strategy
- Market outlook
- Need for immediate liquidity

The protocol provides flexibility to accommodate both aggressive and conservative strategies. 
