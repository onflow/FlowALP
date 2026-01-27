# Interest Rate, Insurance, and Stability Fee Mechanisms

This document describes how interest rates are calculated and how insurance and stability fees are collected in the FlowCreditMarket protocol.

## Overview

The FlowCreditMarket protocol uses a dual-rate interest system:
- **Debit Rate**: The interest rate charged to borrowers
- **Credit Rate**: The interest rate paid to lenders (depositors)

The credit rate is calculated as the debit income minus protocol fees. Protocol fees consist of two components:
- **Insurance Fee**: Collected and converted to MOET to build a permanent insurance reserve for covering bad debt
- **Stability Fee**: Collected in native tokens and available for governance withdrawal to ensure MOET stability

Both fees are deducted from interest income to protect the protocol and fund operations.

## Protocol Fee Components

### Intended Usage

#### Insurance Fund

The insurance fund serves as the protocol's **reserve for covering bad debt**, acting as the liquidator of last resort. A percentage of lender interest income is continuously collected and swapped to MOET, building a safety buffer that grows over time. When there are liquidations that aren't able to be covered and would normally create bad debt in the protocol, the MOET is swapped for that specific asset to cover that delta of bad debt.  These funds are  **never withdrawable** by governance and exist solely to protect lenders from losses.

#### Stability Fund

The stability fund provides **flexible funding for MOET stability operations**. A percentage of lender interest income is collected and held in native token vaults (FLOW, USDC, etc.), with each token type having its own separate vault. These funds can be withdrawn by the governance committee via `withdrawStabilityFund()` to improve the stability of MOET at their discretion—whether by adding liquidity to specific pools, repurchasing MOET if it's trading under peg compared to the underlying basket of assets, or other stabilization strategies. All withdrawals emit `StabilityFundWithdrawn` events for public accountability and transparency.

### Fee Deduction from Lender Returns

Both fees are deducted from the interest income that would otherwise go to lenders:

## Interest Rate Calculation

### 1. Debit Rate Calculation

The debit rate is determined by an interest curve that takes into account the utilization ratio of the pool:

```
debitRate = interestCurve.interestRate(
    creditBalance: totalCreditBalance,
    debitBalance: totalDebitBalance
)
```

The interest curve typically increases the rate as utilization increases, incentivizing borrowers to repay when the pool is highly utilized and encouraging lenders to supply liquidity when rates are high.

### 2. Credit Rate Calculation

The credit rate is derived from the total debit interest income, with insurance and stability fees applied proportionally as a percentage of the interest generated.

For **FixedRateInterestCurve** (used for stable assets like MOET):
```
creditRate = debitRate * (1 - protocolFeeRate)
```

For **KinkInterestCurve** and other curves:
```
debitIncome = totalDebitBalance * debitRate
protocolFeeRate = insuranceRate + stabilityFeeRate
protocolFeeAmount = debitIncome * protocolFeeRate
creditRate = (debitIncome - protocolFeeAmount) / totalCreditBalance
```

**Important**: The combined `insuranceRate + stabilityFeeRate` must be less than 1.0 to avoid underflow in credit rate calculation. This is enforced by preconditions when setting either rate.

### 3. Per-Second Rate Conversion

Both credit and debit rates are converted from annual rates to per-second compounding rates:

```
perSecondRate = (yearlyRate / secondsInYear) + 1.0
```

Where `secondsInYear = 31_557_600` (365.25 days × 24 hours × 60 minutes × 60 seconds).

This conversion allows for continuous compounding of interest over time.

## Interest Accrual Mechanism

### Interest Indices

The protocol uses **interest indices** to track how interest accrues over time. Each token has two indices:
- `creditInterestIndex`: Tracks interest accrual for lender deposits
- `debitInterestIndex`: Tracks interest accrual for borrower debt

### Compounding Interest

Interest compounds continuously using the formula:

```
newIndex = oldIndex * (perSecondRate ^ elapsedSeconds)
```

Where:
- `oldIndex`: The previous interest index value
- `perSecondRate`: The per-second interest rate (1.0 + annualRate/secondsInYear)
- `elapsedSeconds`: Time elapsed since last update

The exponentiation is performed efficiently using exponentiation-by-squaring for performance.

### Balance Conversion

User balances are stored as **scaled balances** (the principal amount) and converted to **true balances** (principal + accrued interest) when needed:

```
trueBalance = scaledBalance * interestIndex
```

This design allows:
- Efficient storage (only principal amounts stored)
- Accurate interest calculation (indices track all accrued interest)
- Fair distribution (interest accrues proportionally to deposit size and time)

### Time Updates

Interest indices are updated whenever:
1. A user interacts with the protocol (deposit, withdraw, borrow, repay)
2. `updateForTimeChange()` is called explicitly
3. `updateInterestRatesAndCollectInsurance()` or `updateInterestRatesAndCollectStability()` is called

The update calculates the time elapsed since `lastUpdate` and compounds the interest indices accordingly.

## Insurance Collection Mechanism

### Overview

The insurance mechanism collects a percentage of interest income over time, swaps it from the underlying token to MOET, and deposits it into a **permanent, non-withdrawable** protocol insurance fund. This fund accumulates over time and can be used to cover protocol losses or other insurance-related purposes.

### Insurance Rate

Each token has a configurable `insuranceRate` (default: 0.0) that represents the annual percentage of interest income that should be collected as insurance.

### Collection Process

Insurance is collected through the `collectInsurance()` function on `TokenState`, which:

1. **Calculates Accrued Insurance**:
   ```
   timeElapsed = currentTime - lastInsuranceCollectionTime
   debitIncome = totalDebitBalance * (currentDebitRate ^ timeElapsed - 1.0)
   insuranceAmount = debitIncome * insuranceRate
   ```

2. **Withdraws from Reserves**:
   - Withdraws the calculated insurance amount from the token's reserve vault
   - If reserves are insufficient, collects only what's available

3. **Swaps to MOET**:
   - Uses the token's configured `insuranceSwapper` to swap from the underlying token to MOET
   - The swapper must be configured per token type and must output MOET
   - Validates that the swapper output type is MOET

4. **Deposits to Insurance Fund**:
   - The collected MOET is deposited into the protocol's insurance fund
   - This fund grows continuously and is never withdrawable

### Integration with Rate Updates

Insurance collection is integrated with interest rate updates through `updateInterestRatesAndCollectInsurance()`:

```cadence
access(self) fun updateInterestRatesAndCollectInsurance(tokenType: Type) {
    // 1. Update interest rates
    tokenState.updateInterestRates()
    
    // 2. Collect insurance
    if let collectedMOET <- tokenState.collectInsurance(reserveVault: reserveRef) {
        // 3. Deposit into insurance fund
        insuranceFund.deposit(from: <-collectedMOET)
    }
}
```

This ensures that:
- Interest rates are recalculated based on current pool state
- Insurance is collected proportionally to time elapsed
- Collected MOET is automatically deposited into the insurance fund

### Configuration Requirements

Before setting a non-zero insurance rate, an insurance swapper must be configured:

```cadence
// First, set insurance swapper for a token type (governance function)
pool.setInsuranceSwapper(tokenType: Type<@FlowToken.Vault>(), swapper: mySwapper)

// Then, set insurance rate (governance function)
pool.setInsuranceRate(tokenType: Type<@FlowToken.Vault>(), insuranceRate: 0.001)
```

The swapper must:
- Accept the token type as input (`inType()`)
- Output MOET (`outType()` == `Type<@MOET.Vault>()`)
- Be validated when set via governance

**Note**: The swapper cannot be removed while the insurance rate is non-zero, and the insurance rate cannot be set to non-zero without a swapper configured.

### Insurance Fund Properties

The Pool maintains a single `insuranceFund` vault that stores all collected MOET tokens:
- Initialized when the Pool is created (empty MOET vault)
- Accumulates MOET over time as insurance is collected from all token types
- Queryable via `insuranceFundBalance()` to see the current balance
- **Never withdrawable by governance** - permanently locked for bad debt coverage
- Grows proportionally to protocol activity, ensuring reserves scale with risk

## Stability Fee Collection Mechanism

### Overview

The stability fee mechanism collects a percentage of interest income over time and holds it in **native token vaults** that are **withdrawable by governance**. These funds are intended to be used for ensuring the stability of MOET.

### Stability Fee Rate

Each token has a configurable `stabilityFeeRate` (default: 0.05 or 5%) that represents the percentage of interest income that should be collected as stability fees.

### Collection Process

Stability fees are collected through the `collectStability()` function on `TokenState`, which:

1. **Calculates Accrued Stability Fee**:
   ```
   timeElapsed = currentTime - lastStabilityFeeCollectionTime
   interestIncome = totalDebitBalance * (currentDebitRate ^ timeElapsed - 1.0)
   stabilityAmount = interestIncome * stabilityFeeRate
   ```

2. **Withdraws from Reserves**:
   - Withdraws the calculated stability amount from the token's reserve vault
   - If reserves are insufficient, collects only what's available

3. **Deposits to Stability Fund**:
   - The collected tokens are deposited into the token-specific stability fund vault
   - No conversion occurs - tokens remain in their native form

### Stability Funds

The Pool maintains separate stability fund vaults for each token type in `stabilityFunds: @{Type: {FungibleToken.Vault}}`:
- Each token type has its own vault (FLOW stability fund, USDC stability fund, etc.)
- Vaults are created when the first stability fee is collected for that token
- Queryable via `getStabilityFundBalance(tokenType)` to see current balance per token
- **Withdrawable by governance** for MOET stability operations

### Governance Withdrawal

Governance can withdraw stability funds to any recipient for MOET stability operations:

```cadence
// Withdraw stability funds (governance only)
pool.withdrawStabilityFund(
    tokenType: Type<@FlowToken.Vault>(),
    amount: 1000.0,
    recipient: recipientReceiver
)
```

This emits a `StabilityFundWithdrawn` event for transparency and accountability.

## Example Flow

### Scenario: Protocol with Active Lending

1. **Initial State**:
   - Total credit balance (lender deposits): 10,000 FLOW
   - Total debit balance (borrower debt): 8,000 FLOW
   - Debit rate: 10% APY
   - Insurance rate: 0.1% (of interest income)
   - Stability fee rate: 5% (of interest income)

2. **After 1 Year**:
   - Current debit rate = 0.10 / 31_557_600 + 1.0 = 1.00000000316880...
   - Debit income: 8,000 × (1.00000000316880^31_557_600 - 1.0) = 841.37 FLOW
   - Insurance collection: 841.37 × 0.001 = 0.841 FLOW → converted to MOET
   - Stability collection: 841.37 × 0.05 = 42.07 FLOW → kept as FLOW
   - Net to lenders: 841.37 - 0.841 - 42.07 = 798.46 FLOW
   - Effective lender APY: 798.46 / 10,000 = 7.98%

3. **Fund Accumulation**:
   - Insurance fund: +0.841 FLOW worth of MOET (permanent, for bad debt coverage)
   - Stability fund (FLOW): +42.07 FLOW (available for MOET stability operations)

## Key Design Decisions

1. **Continuous Compounding**: Interest compounds continuously using per-second rates, providing fair and accurate interest accrual.

2. **Scaled vs True Balances**: Storing scaled balances (principal) separately from interest indices allows efficient storage while maintaining precision.

3. **Dual Fee Structure**: Separating insurance and stability fees serves distinct purposes - permanent bad debt protection vs. operational MOET stability.

4. **Insurance in MOET**: Converting all insurance collections to MOET creates a fungible reserve that can be swapped for any asset needed to cover bad debt.

5. **Insurance Permanence**: Making insurance non-withdrawable ensures the protocol always maintains reserves for bad debt, building lender confidence.

6. **Stability Flexibility**: Keeping stability funds withdrawable in native tokens gives governance flexibility to defend MOET's peg through various strategies.

7. **Time-Based Collection**: Both insurance and stability fees are collected based on time elapsed, ensuring consistent accumulation regardless of transaction frequency.

8. **Token-Specific Swappers**: Each token can have its own insurance swapper, allowing flexibility in how different tokens are converted to MOET.

9. **Unified Insurance Fund**: All collected MOET goes into a single fund, providing a centralized insurance reserve for the protocol.

## Security Considerations

- **Rate Validation**: Both rates are validated to be in range [0, 1) and their sum must be < 1.0
- **Swapper Validation**: Insurance swappers are validated when set to ensure they output MOET
- **Bidirectional Constraints**: Cannot set non-zero insurance rate without swapper; cannot remove swapper with non-zero rate
- **Reserve Checks**: Both collection mechanisms check that sufficient reserves exist before withdrawing
- **Timestamp Tracking**: Separate timestamps (`lastInsuranceCollectionTime`, `lastStabilityFeeCollectionTime`) prevent double-counting
- **Precision**: Uses UFix128 for internal calculations to maintain precision during compounding
- **Access Control**: Only governance (EGovernance entitlement) can modify rates or withdraw stability funds
- **Insurance Lock**: No withdrawal function exists for insurance fund

## Governance Parameters

### Insurance Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `insuranceRate` | Percentage of interest income collected for insurance | 0.0 |
| `insuranceSwapper` | Swapper to convert tokens to MOET (required before enabling) | nil |

These parameters allow the protocol to adjust insurance collection based on risk assessment and market conditions.

### Stability Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `stabilityFeeRate` | Percentage of interest income collected for stability | 0.05 (5%) |

### Governance Functions

- `setInsuranceRate()`: Update insurance rate for a token
- `setInsuranceSwapper()`: Set/update swapper for insurance collection
- `collectInsurance()`: Manually trigger insurance collection
- `setStabilityFeeRate()`: Update stability fee rate for a token
- `collectStability()`: Manually trigger stability fee collection
- `withdrawStabilityFund()`: Withdraw stability funds to a recipient

### Events

| Event | Description |
|-------|-------------|
| `InsuranceRateUpdated` | Emitted when insurance rate changes |
| `InsuranceFeeCollected` | Emitted when insurance is collected and converted to MOET |
| `StabilityFeeRateUpdated` | Emitted when stability fee rate changes |
| `StabilityFeeCollected` | Emitted when stability fee is collected |
| `StabilityFundWithdrawn` | Emitted when governance withdraws stability funds |