# Interest Rate and Insurance Collection Mechanism

This document describes how interest rates are calculated and how insurance is collected in the FlowCreditMarket protocol.

## Overview

The FlowCreditMarket protocol uses a dual-rate interest system:
- **Debit Rate**: The interest rate charged to borrowers
- **Credit Rate**: The interest rate paid to lenders (depositors)

The credit rate is calculated as the debit income minus the insurance fee, ensuring that the protocol maintains an insurance fund while still providing returns to lenders.

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

/// The credit rate is derived from the total debit interest income, with insurance and stability fees applied proportionally as a percentage of the interest generated.

```
debitIncome = totalDebitBalance * debitRate
protocolFeeRate = insuranceRate + stabilityFeeRate
protocolFeeAmount = debitIncome * protocolFeeRate
creditRate = (debitIncome - protocolFeeAmount) / totalCreditBalance
```

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
3. `updateInterestRatesAndCollectInsurance()` is called

The update calculates the time elapsed since `lastUpdate` and compounds the interest indices accordingly.

## Insurance Collection Mechanism

### Overview

The insurance mechanism collects a percentage of the total credit balance over time, swaps it from the underlying token to MOET, and deposits it into a protocol insurance fund. This fund accumulates over time and can be used to cover protocol losses or other insurance-related purposes.

### Insurance Rate

Each token has a configurable `insuranceRate` (default: 0.1% or 0.001) that represents the annual percentage of the total credit balance that should be collected as insurance.

### Collection Process

Insurance is collected through the `collectInsurance()` function on `TokenState`, which:

1. **Calculates Accrued Insurance**:
   ```
   timeElapsed = currentTime - lastInsuranceCollectionTime
   debitIncome = totalDebitBalance * (curentDebitRate ^ time_elapsed - 1.0)
   insuranceAmount = debitIncome * insuranceRate
   ```

2. **Withdraws from Reserves**:
   - Withdraws the calculated insurance amount from the token's reserve vault
   - If reserves are insufficient, collects only what's available

3. **Swaps to MOET**:
   - Uses the token's configured `insuranceSwapper` to swap from the underlying token to MOET
   - The swapper must be configured per token type and must output MOET
   - Validates that the swapper output type is MOET

4. **Returns MOET Vault**:
   - Returns a MOET vault containing the collected insurance
   - The caller (Pool) deposits this into the insurance fund

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

### Configuration

Each token state can have its own insurance swapper configured:

```cadence
// Set insurance swapper for a token type
pool.setInsuranceSwapper(tokenType: Type<@FlowToken.Vault>(), swapper: mySwapper)

// Set insurance rate (governance function)
pool.setInsuranceRate(tokenType: Type<@FlowToken.Vault>(), insuranceRate: 0.001)
```

The swapper must:
- Accept the token type as input (`inType()`)
- Output MOET (`outType()` == `Type<@MOET.Vault>()`)
- Be validated when set via governance

### Insurance Fund

The Pool maintains a single `insuranceFund` vault that stores all collected MOET tokens across all token types. This fund:
- Is initialized when the Pool is created (empty MOET vault)
- Accumulates MOET over time as insurance is collected
- Can be queried via `insuranceFundBalance()` to see the current balance
- Grows continuously as the protocol operates

## Example Flow

### Scenario: User deposits 1000 FLOW tokens

1. **Initial State**:
   - User deposits 1000 FLOW
   - `totalCreditBalance` = 1000 FLOW
   - `creditInterestIndex` = 1.0
   - User's scaled balance = 1000 FLOW

2. **After 1 Year (assuming 5% credit rate)**:
   - `creditInterestIndex` ≈ 1.05 (compounded continuously)
   - User's true balance = 1000 × 1.05 = 1050 FLOW
   - User can withdraw 1050 FLOW

3. **Insurance Collection (0.1% rate)**:
   - Insurance amount = 1000 × 0.001 × 1 year = 1 FLOW per year
   - 1 FLOW is withdrawn from reserves
   - 1 FLOW is swapped to MOET (amount depends on exchange rate)
   - MOET is deposited into insurance fund

4. **Rate Calculation**:
   - If debit rate = 6% and totalDebitBalance = 800 FLOW:
     - `debitIncome` = 800 × 0.06 = 48 FLOW
     - `insuranceAmount` = 1000 × 0.001 = 1 FLOW
     - `creditRate` = (48 - 1) / 1000 = 4.7%
   - Lenders earn 4.7% while 0.1% goes to insurance fund

## Key Design Decisions

1. **Continuous Compounding**: Interest compounds continuously using per-second rates, providing fair and accurate interest accrual.

2. **Scaled vs True Balances**: Storing scaled balances (principal) separately from interest indices allows efficient storage while maintaining precision.

3. **Insurance as Deduction**: Insurance is deducted from lender returns rather than being an additional fee, ensuring the protocol always maintains an insurance fund.

4. **Time-Based Collection**: Insurance is collected based on time elapsed, ensuring consistent accumulation regardless of transaction frequency.

5. **Token-Specific Swappers**: Each token can have its own swapper, allowing flexibility in how different tokens are converted to MOET.

6. **Unified Insurance Fund**: All collected MOET goes into a single fund, providing a centralized insurance reserve for the protocol.

## Security Considerations

- **Rate Validation**: Interest rates are validated to prevent overflow/underflow
- **Swapper Validation**: Insurance swappers are validated when set to ensure they output MOET
- **Reserve Checks**: Insurance collection checks that sufficient reserves exist before withdrawing
- **Timestamp Tracking**: `lastInsuranceCollectionTime` prevents double-counting of insurance periods
- **Precision**: Uses UFix128 for internal calculations to maintain precision during compounding

## Governance

The following parameters can be configured via governance:
- `insuranceRate`: The annual insurance rate (0.0 to 1.0)
- `insuranceSwapper`: The swapper used to convert tokens to MOET (per token type)

These parameters allow the protocol to adjust insurance collection based on risk assessment and market conditions.
