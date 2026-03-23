# Interest Rate, Insurance, and Stability Fee Mechanisms

This document describes how interest rates are calculated and how insurance and stability fees are collected in the FlowALP protocol (as implemented by `FlowALPv0`).

## Overview

The FlowALP protocol uses a dual-rate interest system:
- **Debit Rate**: The interest rate charged to borrowers
- **Credit Rate**: The interest rate paid to lenders (depositors)

The credit rate is derived from the debit rate after deducting protocol fees. Protocol fees consist of two components:
- **Insurance Fee**: Collected and converted to MOET to build a permanent insurance reserve for covering bad debt
- **Stability Fee**: Collected in native tokens and available for governance withdrawal to ensure MOET stability

Both fees come out of the spread between debit and credit income — they do not reduce the borrower's rate, they reduce the fraction of that income returned to lenders.

## Protocol Fee Components

### Intended Usage

#### Insurance Fund

The insurance fund serves as the protocol's **reserve for covering bad debt**, acting as the liquidator of last resort. A percentage of protocol spread income is collected as interest accrues and swapped to MOET, building a safety buffer that grows over time. When there are liquidations that aren't able to be covered and would normally create bad debt in the protocol, the MOET is swapped for that specific asset to cover that delta of bad debt. These funds are **never withdrawable** by governance and exist solely to protect lenders from losses.

#### Stability Fund

The stability fund provides **flexible funding for MOET stability operations**. A percentage of protocol spread income is collected and held in native token vaults (FLOW, USDC, etc.), with each token type having its own separate vault. These funds can be withdrawn by the governance committee via `withdrawStabilityFund()` to improve the stability of MOET at their discretion—whether by adding liquidity to specific pools, repurchasing MOET if it's trading under peg compared to the underlying basket of assets, or other stabilization strategies. All withdrawals emit `StabilityFundWithdrawn` events for public accountability and transparency.

### Fee Deduction from Lender Returns

Both fees are deducted from the spread income that would otherwise go to lenders:

## Interest Rate Calculation

### 1. Debit Rate Calculation

For each token, the protocol stores one interest curve. The debit rate (borrow nominal yearly rate) is computed from that curve and the current pool utilization:

```text
if totalDebitBalance == 0:
    utilization = 0
else if totalCreditBalance == 0:
    utilization = 100%
else:
    utilization = min(totalDebitBalance / totalCreditBalance, 1.0)

debitRate = interestCurve.interestRate(
    creditBalance: totalCreditBalance,
    debitBalance: totalDebitBalance
)
```

Here, `totalCreditBalance` means the total supplied balance, i.e. total creditor claims. It does not mean the remaining idle liquidity in the pool.

Under this accounting model, FlowALP's utilization matches the Aave-style reserve usage ratio after mapping variables:

```
totalCreditBalance = availableLiquidity + totalDebitBalance
```

Utilization in this model is:
- `0%` when there is no debt
- `40%` when `40` is borrowed against `100` supplied
- `100%` when debit and credit balances are equal
- capped at `100%` in defensive edge cases where debt exceeds supply or supply is zero while debt remains positive

### FixedCurve (constant nominal yearly rate)

For `FixedCurve`, the debit nominal yearly rate is constant regardless of utilization:

```
debitRate = yearlyRate
```

Example:
- `yearlyRate = 0.05` (5% nominal yearly rate)
- the debit nominal yearly rate stays at 5% whether utilization is 10% or 95%

### KinkCurve (utilization-based nominal yearly rate)

For `KinkCurve`, the debit nominal yearly rate follows a two-segment curve:
- below `optimalUtilization` ("before the kink"), rates rise gently
- above `optimalUtilization` ("after the kink"), rates rise steeply

Definitions:

```
u = utilization
u* = optimalUtilization
```

If `u <= u*`:

```
debitRate = baseRate + slope1 * (u / u*)
```

If `u > u*`:

```
debitRate = baseRate + slope1 + slope2 * ((u - u*) / (1 - u*))
```

At full utilization (`u = 100%`), the rate is:

```
maxDebitRate = baseRate + slope1 + slope2
```

#### Example profile (Aave v3 "Volatile One" style)

Reference values discussed for volatile assets:
- Source: https://github.com/onflow/FlowYieldVaults/pull/108#discussion_r2688322723
- `optimalUtilization = 45%` (`0.45`)
- `baseRate = 0%` (`0.0`)
- `slope1 = 4%` (`0.04`)
- `slope2 = 300%` (`3.0`)

Interpretation:
- at or below 45% utilization, borrowers see relatively low/gradual nominal-rate increases
- above 45%, the nominal yearly rate increases very aggressively to push utilization back down
- theoretical max debit nominal yearly rate at 100% utilization is `304%` (`0% + 4% + 300%`)

This is the mechanism that helps protect withdrawal liquidity under stress.

### 2. Credit Rate Calculation

The credit rate is derived from the **per-second** debit rate, not the nominal annual rate directly. This is important: the protocol computes per-second rates first and then scales the credit side, not the other way around.

Shared definitions:

```
protocolFeeRate = insuranceRate + stabilityFeeRate
debitRatePerSecond = perSecondInterestRate(yearlyRate: debitRate) - 1.0
```

and `protocolFeeRate` must be `< 1.0`.

For **FixedCurve** (used for stable assets like MOET):
```
currentCreditRate = 1.0 + debitRatePerSecond * (1.0 - protocolFeeRate)
```

The per-second credit excess is the debit excess scaled down by `(1 - protocolFeeRate)`. This is a fixed spread at the per-second level, independent of utilization.

For **KinkCurve** and other non-fixed curves (reserve factor model):
```
currentCreditRate = 1.0 + debitRatePerSecond * (1.0 - protocolFeeRate) * totalDebitBalance / totalCreditBalance
```

The per-second credit excess is further scaled by the utilization ratio (`totalDebit / totalCredit`). This ensures the total interest paid by borrowers equals the total interest earned by lenders plus protocol fees, regardless of the utilization level.

**Important**: The combined `insuranceRate + stabilityFeeRate` must be less than 1.0 to avoid underflow in credit rate calculation. This is enforced by preconditions when setting either rate.

### 3. Per-Second Rate Conversion

The nominal annual debit rate is converted to a per-second compounding rate:

```
perSecondDebitRate = (yearlyRate / secondsInYear) + 1.0
```

Where `secondsInYear = 31_557_600` (365.25 days × 24 hours × 60 minutes × 60 seconds).

The credit rate is **not** converted from an annual rate independently — it is derived directly in per-second terms from the per-second debit rate (see Section 2 above).

Important terminology: the configured `yearlyRate` is a **nominal yearly rate**, not a promise that a balance will grow by exactly that percentage over one calendar year. For positive fixed rates, the effective one-year growth is slightly higher because of compounding. For variable curves, realized growth also depends on when utilization changes and the rate is recomputed.

### 4. Querying Curve Parameters On-Chain

The pool exposes `getInterestCurveParams(tokenType)` and the repo includes script:
- `cadence/scripts/flow-alp/get_interest_curve_params.cdc`

Returned fields:
- Always: `curveType`, `currentDebitRatePerSecond`, `currentCreditRatePerSecond`
- FixedCurve: `yearlyRate`
- KinkCurve: `optimalUtilization`, `baseRate`, `slope1`, `slope2`


## Interest Accrual Mechanism

### Interest Indices

The protocol uses **interest indices** to track how interest accrues over time. Each token has two indices:
- `creditInterestIndex`: Tracks interest accrual for lender deposits
- `debitInterestIndex`: Tracks interest accrual for borrower debt

### Compounding Interest

Interest compounds via discrete per-second updates using the formula:

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

The update calculates the time elapsed since `lastUpdate` and compounds the interest indices accordingly. When rates are variable, realized growth over a period depends on the sequence of utilization changes and the rate recomputations they trigger, so the displayed yearly rate should not be interpreted as an exact promised one-year payoff.

## Protocol Fee Accumulation

### `collectProtocolFees()` Accumulator

Insurance and stability fees are both computed in a single `TokenState.collectProtocolFees()` method. It is called automatically before every balance or rate mutation to ensure fees settle at the rate that was in effect when they accrued:

```
timeElapsed = currentTime - lastProtocolFeeCollectionTime
debitIncome  = totalDebitBalance  * (currentDebitRate  ^ timeElapsed - 1.0)
creditIncome = totalCreditBalance * (currentCreditRate ^ timeElapsed - 1.0)
protocolFeeIncome = max(0, debitIncome - creditIncome)

insuranceFeeAmount = protocolFeeIncome * insuranceRate / (insuranceRate + stabilityFeeRate)
stabilityFeeAmount = protocolFeeIncome - insuranceFeeAmount

accumulatedInsuranceFeeIncome  += insuranceFeeAmount
accumulatedStabilityFeeIncome  += stabilityFeeAmount
lastProtocolFeeCollectionTime   = currentTime
```

`protocolFeeIncome` is the spread between what borrowers pay and what lenders earn. At any utilization level, this is a positive number as long as `protocolFeeRate > 0`. At zero utilization (no borrowers) or zero protocol fee rate, `protocolFeeIncome = 0`.

The two accumulators are read and reset by `_withdrawInsurance` and `_withdrawStability` respectively.

### When Fees Are Settled

`collectProtocolFees()` is triggered on every mutation that could change the fee calculation:
- `increaseCreditBalance` / `decreaseCreditBalance`
- `increaseDebitBalance` / `decreaseDebitBalance`
- `setInterestCurve`
- `setInsuranceRate`
- `setStabilityFeeRate`

This means changing any rate always settles all accrued fees at the **old** rate first, then applies the new rate going forward.

## Insurance Collection Mechanism

### Overview

The insurance mechanism collects a share of protocol spread income over time, swaps it from the underlying token to MOET, and deposits it into a **permanent, non-withdrawable** protocol insurance fund. This fund accumulates over time and can be used to cover protocol losses or other insurance-related purposes.

### Insurance Rate

Each token has a configurable `insuranceRate` (default: 0.0) that represents the fraction of protocol spread income allocated to insurance when fees are settled.

### Collection Process

Insurance is collected through `collectInsurance()` function on `Pool` in `FlowALPv0`, which:

1. **Reads the Accumulated Insurance**:
   ```
   insuranceAmount = tokenState.accumulatedInsuranceFeeIncome
   (reset to 0 after reading)
   ```
   The accumulation itself happens in `collectProtocolFees()` (see above).

2. **Withdraws from Reserves**:
   - Withdraws the calculated insurance amount from the token's reserve vault
   - If reserves are insufficient, no collection occurs and the accumulated amount remains for the next attempt

3. **Swaps to MOET**:
   - Uses the token's configured `insuranceSwapper` to swap from the underlying token to MOET
   - The swapper must be configured per token type and must output MOET
   - Validates that the swapper output type is MOET

4. **Deposits to Insurance Fund**:
   - The collected MOET is deposited into the protocol's insurance fund
   - This fund grows as insurance is collected and is never withdrawable

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

The stability fee mechanism collects a share of protocol spread income over time and holds it in **native token vaults** that are **withdrawable by governance**. These funds are intended to be used for ensuring the stability of MOET.

### Stability Fee Rate

Each token has a configurable `stabilityFeeRate` (default: 0.05 or 5%) that represents the fraction of protocol spread income allocated to stability fees when they are settled.

### Collection Process

Stability fees are collected through `_withdrawStability()` in `FlowALPv0`, which:

1. **Reads the Accumulated Stability Fee**:
   ```
   stabilityAmount = tokenState.accumulatedStabilityFeeIncome
   (reset to 0 after reading)
   ```
   The accumulation itself happens in `collectProtocolFees()` (see above).

2. **Withdraws from Reserves**:
   - Withdraws the calculated stability amount from the token's reserve vault
   - If reserves are insufficient, no collection occurs and the accumulated amount remains for the next attempt

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

### Scenario: Protocol with Active Lending (KinkCurve)

1. **Initial State**:
   - Total credit balance (lender deposits): 10,000 FLOW
   - Total debit balance (borrower debt): 8,000 FLOW  → utilization U = 0.8
   - Debit nominal yearly rate: 10%
   - Insurance rate: 0.1% (`0.001`)
   - Stability fee rate: 5% (`0.05`)
   - `protocolFeeRate = 0.001 + 0.05 = 0.051`

2. **Per-Second Rates**:
   - `debitRatePerSec = 0.10 / 31_557_600 ≈ 3.169e-9`
   - `currentDebitRate = 1 + 3.169e-9`
   - KinkCurve path: `currentCreditRate = 1 + 3.169e-9 × (1 - 0.051) × 0.8 = 1 + 2.406e-9`

3. **After 1 Year**:
   - `debitIncome  = 8,000 × (perSecondDebitRate ^ 31_557_600 − 1) ≈ 841.37 FLOW`
   - `creditIncome = 10,000 × (perSecondCreditRate ^ 31_557_600 − 1) ≈ 792.54 FLOW`
   - `protocolFeeIncome = 841.37 − 792.54 = 48.83 FLOW`
   - `insuranceFee = 48.83 × 0.001 / 0.051 ≈ 0.957 FLOW` → converted to MOET
   - `stabilityFee = 48.83 × 0.050 / 0.051 ≈ 47.87 FLOW` → kept as FLOW
   - Net lender return = creditIncome = 792.54 FLOW
   - Effective lender yield over the year: 792.54 / 10,000 ≈ 7.93%

4. **Fund Accumulation**:
   - Insurance fund: +0.957 FLOW worth of MOET (permanent, for bad debt coverage)
   - Stability fund (FLOW): +47.87 FLOW (available for MOET stability operations)

## Key Design Decisions

1. **Discrete Per-Second Compounding**: Interest compounds via per-second updates, providing fair and accurate interest accrual.

2. **Scaled vs True Balances**: Storing scaled balances (principal) separately from interest indices allows efficient storage while maintaining precision.

3. **Dual Fee Structure**: Separating insurance and stability fees serves distinct purposes - permanent bad debt protection vs. operational MOET stability.

4. **Insurance in MOET**: Converting all insurance collections to MOET creates a fungible reserve that can be swapped for any asset needed to cover bad debt.

5. **Insurance Permanence**: Making insurance non-withdrawable ensures the protocol always maintains reserves for bad debt, building lender confidence.

6. **Stability Flexibility**: Keeping stability funds withdrawable in native tokens gives governance flexibility to defend MOET's peg through various strategies.

7. **Spread-Based Fee Formula**: Fees are taken from `debitIncome - creditIncome` (the spread), not from gross debit income. This ensures that at zero utilization or zero protocol fee rate no fees are collected, and that the fee split between insurance and stability is always exact regardless of curve type.

8. **Single `collectProtocolFees()` Accumulator**: A single shared accumulator and timestamp for both fees ensures they always use the same elapsed-time window and that a rate change for one fee type does not inadvertently double-count or skip the other.

9. **Token-Specific Swappers**: Each token can have its own insurance swapper, allowing flexibility in how different tokens are converted to MOET.

10. **Unified Insurance Fund**: All collected MOET goes into a single fund, providing a centralized insurance reserve for the protocol.

## Security Considerations

- **Rate Validation**: Both rates are validated to be in range [0, 1) and their sum must be < 1.0
- **Swapper Validation**: Insurance swappers are validated when set to ensure they output MOET
- **Bidirectional Constraints**: Cannot set non-zero insurance rate without swapper; cannot remove swapper with non-zero rate
- **Reserve Checks**: Both collection mechanisms check that sufficient reserves exist before withdrawing
- **Timestamp Tracking**: A single `lastProtocolFeeCollectionTime` shared by both fees prevents double-counting across the insurance/stability split
- **Precision**: Uses UFix128 for internal calculations to maintain precision during compounding
- **Access Control**: Only governance (EGovernance entitlement) can modify rates or withdraw stability funds
- **Insurance Lock**: No withdrawal function exists for insurance fund

## Governance Parameters

### Insurance Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `insuranceRate` | Fraction of protocol spread income allocated to insurance | 0.0 |
| `insuranceSwapper` | Swapper to convert tokens to MOET (required before enabling) | nil |

These parameters allow the protocol to adjust insurance collection based on risk assessment and market conditions.

### Stability Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `stabilityFeeRate` | Fraction of protocol spread income allocated to stability fees | 0.05 (5%) |

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
