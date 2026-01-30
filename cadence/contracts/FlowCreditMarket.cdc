import "Burner"
import "FungibleToken"
import "ViewResolver"

import "DeFiActionsUtils"
import "DeFiActions"
import "MOET"
import "FlowCreditMarketMath"

access(all) contract FlowCreditMarket {

    // Design notes: Fixed-point and 128-bit usage:
    // - Interest indices and rates are maintained in 128-bit fixed-point to avoid precision loss during compounding.
    // - External-facing amounts remain UFix64.
    //   Promotions to 128-bit occur only for internal math that multiplies by indices/rates.
    //   This strikes a balance between precision and ergonomics while keeping on-chain math safe.

    /// The canonical StoragePath where the primary FlowCreditMarket Pool is stored
    access(all) let PoolStoragePath: StoragePath

    /// The canonical StoragePath where the PoolFactory resource is stored
    access(all) let PoolFactoryPath: StoragePath

    /// The canonical PublicPath where the primary FlowCreditMarket Pool can be accessed publicly
    access(all) let PoolPublicPath: PublicPath

    access(all) let PoolCapStoragePath: StoragePath

    /* --- EVENTS ---- */

    // Prefer Type in events for stronger typing; off-chain can stringify via .identifier

    access(all) event Opened(
        pid: UInt64,
        poolUUID: UInt64
    )

    access(all) event Deposited(
        pid: UInt64,
        poolUUID: UInt64,
        vaultType: Type,
        amount: UFix64,
        depositedUUID: UInt64
    )

    access(all) event Withdrawn(
        pid: UInt64,
        poolUUID: UInt64,
        vaultType: Type,
        amount: UFix64,
        withdrawnUUID: UInt64
    )

    access(all) event Rebalanced(
        pid: UInt64,
        poolUUID: UInt64,
        atHealth: UFix128,
        amount: UFix64,
        fromUnder: Bool
    )

    /// Consolidated liquidation params update event including all updated values
    access(all) event LiquidationParamsUpdated(
        poolUUID: UInt64,
        targetHF: UFix128,
        warmupSec: UInt64,
    )

    access(all) event LiquidationsPaused(
        poolUUID: UInt64
    )

    access(all) event LiquidationsUnpaused(
        poolUUID: UInt64,
        warmupEndsAt: UInt64
    )

    access(all) event LiquidationExecuted(
        pid: UInt64,
        poolUUID: UInt64,
        debtType: String,
        repayAmount: UFix64,
        seizeType: String,
        seizeAmount: UFix64,
        newHF: UFix128
    )

    access(all) event LiquidationExecutedViaDex(
        pid: UInt64,
        poolUUID: UInt64,
        seizeType: String,
        seized: UFix64,
        debtType: String,
        repaid: UFix64,
        slippageBps: UInt16,
        newHF: UFix128
    )

    access(all) event PriceOracleUpdated(
        poolUUID: UInt64,
        newOracleType: String
    )

    access(all) event InterestCurveUpdated(
        poolUUID: UInt64,
        tokenType: String,
        curveType: String
    )

    access(all) event DepositCapacityRegenerated(
        tokenType: Type,
        oldCapacityCap: UFix64,
        newCapacityCap: UFix64
    )

    access(all) event DepositCapacityConsumed(
        tokenType: Type,
        pid: UInt64,
        amount: UFix64,
        remainingCapacity: UFix64
    )

    //// Emitted each time the insurance rate is updated for a specific token in a specific pool.
    //// The insurance rate is an annual percentage; for example a value of 0.001 indicates 0.1%.
    access(all) event InsuranceRateUpdated(
        poolUUID: UInt64,
        tokenType: String,
        insuranceRate: UFix64,
    )

    /// Emitted each time an insurance fee is collected for a specific token in a specific pool.
    /// The insurance amount is the amount of insurance collected, denominated in MOET.
    access(all) event InsuranceFeeCollected(
        poolUUID: UInt64,
        tokenType: String,
        insuranceAmount: UFix64,
        collectionTime: UFix64,
    )

    //// Emitted each time the stability rate is updated for a specific token in a specific pool.
    //// The stability rate is an annual percentage; the default value is 0.05 (5%).
    access(all) event StabilityFeeRateUpdated(
        poolUUID: UInt64,
        tokenType: String,
        stabilityFeeRate: UFix64,
    )

    /// Emitted each time an stability fee is collected for a specific token in a specific pool.
    /// The stability amount is the amount of stability collected, denominated in token type.
    access(all) event StabilityFeeCollected(
        poolUUID: UInt64,
        tokenType: String,
        stabilityAmount: UFix64,
        collectionTime: UFix64,
    )

    /// Emitted each time funds are withdrawn from the stability fund for a specific token in a specific pool.
    /// The amount is the quantity withdrawn, denominated in the token type.
    access(all) event StabilityFundWithdrawn(
        poolUUID: UInt64,
        tokenType: String,
        amount: UFix64,
    )

    /* --- CONSTRUCTS & INTERNAL METHODS ---- */

    access(all) entitlement EPosition
    access(all) entitlement EGovernance
    access(all) entitlement EImplementation
    access(all) entitlement EParticipant

    /* --- NUMERIC TYPES POLICY ---
        - External/public APIs (Vault amounts, deposits/withdrawals, events) use UFix64.
        - Internal accounting and risk math use UFix128: scaled/true balances, interest indices/rates,
          health factor, and prices once converted.
        Rationale:
        - Interest indices and rates are modeled as 18-decimal fixed-point in FlowCreditMarketMath and stored as UFix128.
        - Operating in the UFix128 domain minimizes rounding error in true↔scaled conversions and
          health/price computations.
        - We convert at boundaries via type casting to UFix128 or FlowCreditMarketMath.toUFix64.
    */

    /// InternalBalance
    ///
    /// A structure used internally to track a position's balance for a particular token
    access(all) struct InternalBalance {

        /// The current direction of the balance - Credit (owed to borrower) or Debit (owed to protocol)
        access(all) var direction: BalanceDirection

        /// Internally, position balances are tracked using a "scaled balance".
        /// The "scaled balance" is the actual balance divided by the current interest index for the associated token.
        /// This means we don't need to update the balance of a position as time passes, even as interest rates change.
        /// We only need to update the scaled balance when the user deposits or withdraws funds.
        /// The interest index is a number relatively close to 1.0,
        /// so the scaled balance will be roughly of the same order of magnitude as the actual balance.
        /// We store the scaled balance as UFix128 to align with UFix128 interest indices
        // and to reduce rounding during true ↔ scaled conversions.
        access(all) var scaledBalance: UFix128

        // Single initializer that can handle both cases
        init(
            direction: BalanceDirection,
            scaledBalance: UFix128
        ) {
            self.direction = direction
            self.scaledBalance = scaledBalance
        }

        /// Records a deposit of the defined amount, updating the inner scaledBalance as well as relevant values
        /// in the provided TokenState.
        ///
        /// It's assumed the TokenState and InternalBalance relate to the same token Type,
        /// but since neither struct have values defining the associated token,
        /// callers should be sure to make the arguments do in fact relate to the same token Type.
        ///
        /// amount is expressed in UFix128 (true token units) to operate in the internal UFix128 domain;
        /// public deposit APIs accept UFix64 and are converted at the boundary.
        ///
        access(contract) fun recordDeposit(amount: UFix128, tokenState: auth(EImplementation) &TokenState) {
            switch self.direction {
                case BalanceDirection.Credit:
                    // Depositing into a credit position just increases the balance.
                    //
                    // To maximize precision, we could convert the scaled balance to a true balance,
                    // add the deposit amount, and then convert the result back to a scaled balance.
                    //
                    // However, this will only cause problems for very small deposits (fractions of a cent),
                    // so we save computational cycles by just scaling the deposit amount
                    // and adding it directly to the scaled balance.

                    let scaledDeposit = FlowCreditMarket.trueBalanceToScaledBalance(
                        amount,
                        interestIndex: tokenState.creditInterestIndex
                    )

                    self.scaledBalance = self.scaledBalance + scaledDeposit

                    // Increase the total credit balance for the token
                    tokenState.increaseCreditBalance(by: amount)

                case BalanceDirection.Debit:
                    // When depositing into a debit position, we first need to compute the true balance
                    // to see if this deposit will flip the position from debit to credit.

                    let trueBalance = FlowCreditMarket.scaledBalanceToTrueBalance(
                        self.scaledBalance,
                        interestIndex: tokenState.debitInterestIndex
                    )

                    // Harmonize comparison with withdrawal: treat an exact match as "does not flip to credit"
                    if trueBalance >= amount {
                        // The deposit isn't big enough to clear the debt,
                        // so we just decrement the debt.
                        let updatedBalance = trueBalance - amount

                        self.scaledBalance = FlowCreditMarket.trueBalanceToScaledBalance(
                            updatedBalance,
                            interestIndex: tokenState.debitInterestIndex
                        )

                        // Decrease the total debit balance for the token
                        tokenState.decreaseDebitBalance(by: amount)

                    } else {
                        // The deposit is enough to clear the debt,
                        // so we switch to a credit position.
                        let updatedBalance = amount - trueBalance

                        self.direction = BalanceDirection.Credit
                        self.scaledBalance = FlowCreditMarket.trueBalanceToScaledBalance(
                            updatedBalance,
                            interestIndex: tokenState.creditInterestIndex
                        )

                        // Increase the credit balance AND decrease the debit balance
                        tokenState.increaseCreditBalance(by: updatedBalance)
                        tokenState.decreaseDebitBalance(by: trueBalance)
                    }
            }
        }

        /// Records a withdrawal of the defined amount, updating the inner scaledBalance
        /// as well as relevant values in the provided TokenState.
        ///
        /// It's assumed the TokenState and InternalBalance relate to the same token Type,
        /// but since neither struct have values defining the associated token,
        /// callers should be sure to make the arguments do in fact relate to the same token Type.
        ///
        /// amount is expressed in UFix128 for the same rationale as deposits;
        /// public withdraw APIs are UFix64 and are converted at the boundary.
        ///
        access(contract) fun recordWithdrawal(amount: UFix128, tokenState: auth(EImplementation) &TokenState) {
            switch self.direction {
                case BalanceDirection.Debit:
                    // Withdrawing from a debit position just increases the debt amount.
                    //
                    // To maximize precision, we could convert the scaled balance to a true balance,
                    // subtract the withdrawal amount, and then convert the result back to a scaled balance.
                    //
                    // However, this will only cause problems for very small withdrawals (fractions of a cent),
                    // so we save computational cycles by just scaling the withdrawal amount
                    // and subtracting it directly from the scaled balance.

                    let scaledWithdrawal = FlowCreditMarket.trueBalanceToScaledBalance(
                        amount,
                        interestIndex: tokenState.debitInterestIndex
                    )

                    self.scaledBalance = self.scaledBalance + scaledWithdrawal

                    // Increase the total debit balance for the token
                    tokenState.increaseDebitBalance(by: amount)

                case BalanceDirection.Credit:
                    // When withdrawing from a credit position,
                    // we first need to compute the true balance
                    // to see if this withdrawal will flip the position from credit to debit.
                    let trueBalance = FlowCreditMarket.scaledBalanceToTrueBalance(
                        self.scaledBalance,
                        interestIndex: tokenState.creditInterestIndex
                    )

                    if trueBalance >= amount {
                        // The withdrawal isn't big enough to push the position into debt,
                        // so we just decrement the credit balance.
                        let updatedBalance = trueBalance - amount

                        self.scaledBalance = FlowCreditMarket.trueBalanceToScaledBalance(
                            updatedBalance,
                            interestIndex: tokenState.creditInterestIndex
                        )

                        // Decrease the total credit balance for the token
                        tokenState.decreaseCreditBalance(by: amount)
                    } else {
                        // The withdrawal is enough to push the position into debt,
                        // so we switch to a debit position.
                        let updatedBalance = amount - trueBalance

                        self.direction = BalanceDirection.Debit
                        self.scaledBalance = FlowCreditMarket.trueBalanceToScaledBalance(
                            updatedBalance,
                            interestIndex: tokenState.debitInterestIndex
                        )

                        // Decrease the credit balance AND increase the debit balance
                        tokenState.decreaseCreditBalance(by: trueBalance)
                        tokenState.increaseDebitBalance(by: updatedBalance)
                    }
            }
        }
    }

    /// BalanceSheet
    ///
    /// An struct containing a position's overview in terms of its effective collateral and debt
    /// as well as its current health.
    access(all) struct BalanceSheet {

        /// Effective collateral is a normalized valuation of collateral deposited into this position, denominated in $.
        /// In combination with effective debt, this determines how much additional debt can be taken out by this position.
        access(all) let effectiveCollateral: UFix128

        /// Effective debt is a normalized valuation of debt withdrawn against this position, denominated in $.
        /// In combination with effective collateral, this determines how much additional debt can be taken out by this position.
        access(all) let effectiveDebt: UFix128

        /// The health of the related position
        access(all) let health: UFix128

        init(
            effectiveCollateral: UFix128,
            effectiveDebt: UFix128
        ) {
            self.effectiveCollateral = effectiveCollateral
            self.effectiveDebt = effectiveDebt
            self.health = FlowCreditMarket.healthComputation(
                effectiveCollateral: effectiveCollateral,
                effectiveDebt: effectiveDebt
            )
        }
    }

    /// Liquidation parameters view (global)
    access(all) struct LiquidationParamsView {
        access(all) let targetHF: UFix128
        access(all) let paused: Bool
        access(all) let warmupSec: UInt64
        access(all) let lastUnpausedAt: UInt64?
        access(all) let triggerHF: UFix128
        /// Deprecated: Unused field, but cannot be removed without contract update
        access(all) let protocolFeeBps: UInt16

        init(
            targetHF: UFix128,
            paused: Bool,
            warmupSec: UInt64,
            lastUnpausedAt: UInt64?,
            triggerHF: UFix128,
        ) {
            self.targetHF = targetHF
            self.paused = paused
            self.warmupSec = warmupSec
            self.lastUnpausedAt = lastUnpausedAt
            self.triggerHF = triggerHF
            self.protocolFeeBps = 0
        }
    }

    /// Entitlement mapping enabling authorized references on nested resources within InternalPosition
    access(all) entitlement mapping ImplementationUpdates {
        EImplementation -> Mutate
        EImplementation -> FungibleToken.Withdraw
    }

    /// InternalPosition
    ///
    /// An internal resource used to track deposits, withdrawals, balances, and queued deposits to an open position.
    access(all) resource InternalPosition {

        /// The position-specific target health, for auto-balancing purposes.
        /// When the position health moves outside the range [minHealth, maxHealth], the balancing operation
        /// should result in a position health of targetHealth.
        access(EImplementation) var targetHealth: UFix128

        /// The position-specific minimum health threshold, below which a position is considered undercollateralized.
        /// When a position is under-collateralized, it is eligible for rebalancing.
        /// NOTE: An under-collateralized position is distinct from an unhealthy position, and cannot be liquidated
        access(EImplementation) var minHealth: UFix128

        /// The position-specific maximum health threshold, above which a position is considered overcollateralized.
        /// When a position is over-collateralized, it is eligible for rebalancing.
        access(EImplementation) var maxHealth: UFix128

        /// The balances of deposited and withdrawn token types
        access(mapping ImplementationUpdates) var balances: {Type: InternalBalance}

        /// Funds that have been deposited but must be asynchronously added to the Pool's reserves and recorded
        access(mapping ImplementationUpdates) var queuedDeposits: @{Type: {FungibleToken.Vault}}

        /// A DeFiActions Sink that if non-nil will enable the Pool to push overflown value automatically when the
        /// position exceeds its maximum health based on the value of deposited collateral versus withdrawals
        access(mapping ImplementationUpdates) var drawDownSink: {DeFiActions.Sink}?

        /// A DeFiActions Source that if non-nil will enable the Pool to pull underflown value automatically when the
        /// position falls below its minimum health based on the value of deposited collateral versus withdrawals.
        ///
        /// If this value is not set, liquidation may occur in the event of undercollateralization.
        access(mapping ImplementationUpdates) var topUpSource: {DeFiActions.Source}?

        init() {
            self.balances = {}
            self.queuedDeposits <- {}
            self.targetHealth = 1.3
            self.minHealth = 1.1
            self.maxHealth = 1.5
            self.drawDownSink = nil
            self.topUpSource = nil
        }

        /// Sets the Position's target health
        access(EImplementation) fun setTargetHealth(_ value: UFix128) {
            self.targetHealth = value
        }

        /// Sets the Position's minimum health
        access(EImplementation) fun setMinHealth(_ value: UFix128) {
            self.minHealth = value
        }

        /// Sets the Position's maximum health
        access(EImplementation) fun setMaxHealth(_ value: UFix128) {
            self.maxHealth = value
        }

        /// Returns a value-copy of `balances` suitable for constructing a `PositionView`.
        access(all) fun copyBalances(): {Type: InternalBalance} {
            return self.balances
        }

        /// Sets the InternalPosition's drawDownSink. If `nil`, the Pool will not be able to push overflown value when
        /// the position exceeds its maximum health.
        ///
        /// NOTE: If a non-nil value is provided, the Sink MUST accept MOET deposits or the operation will revert.
        /// TODO(jord): precondition assumes Pool's default token is MOET, however Pool has option to specify default token in constructor.
        access(EImplementation) fun setDrawDownSink(_ sink: {DeFiActions.Sink}?) {
            pre {
                sink == nil || sink!.getSinkType() == Type<@MOET.Vault>():
                    "Invalid Sink provided - Sink must accept MOET"
            }
            self.drawDownSink = sink
        }

        /// Sets the InternalPosition's topUpSource. If `nil`, the Pool will not be able to pull underflown value when
        /// the position falls below its minimum health which may result in liquidation.
        access(EImplementation) fun setTopUpSource(_ source: {DeFiActions.Source}?) {
            /// TODO(jord): User can provide top-up source containing unsupported token type. Then later rebalances will revert.
            /// Possibly an attack vector on automated rebalancing, if multiple positions are rebalanced in the same transaction.
            self.topUpSource = source
        }
    }

    /// InterestCurve
    ///
    /// A simple interface to calculate interest rate for a token type.
    access(all) struct interface InterestCurve {
        /// Returns the annual interest rate for the given credit and debit balance, for some token T.
        /// @param creditBalance The credit (deposit) balance of token T
        /// @param debitBalance The debit (withdrawal) balance of token T
        access(all) fun interestRate(creditBalance: UFix128, debitBalance: UFix128): UFix128 {
            post {
                // Max rate is 400% (4.0) to accommodate high-utilization scenarios
                // with kink-based curves like Aave v3's interest rate strategy
                result <= 4.0:
                    "Interest rate can't exceed 400%"
            }
        }
    }

    /// FixedRateInterestCurve
    ///
    /// A fixed-rate interest curve implementation that returns a constant yearly interest rate
    /// regardless of utilization. This is suitable for stable assets like MOET where predictable
    /// rates are desired.
    /// @param yearlyRate The fixed yearly interest rate as a UFix128 (e.g., 0.05 for 5% APY)
    access(all) struct FixedRateInterestCurve: InterestCurve {

        access(all) let yearlyRate: UFix128

        init(yearlyRate: UFix128) {
            pre {
                yearlyRate <= 1.0: "Yearly rate cannot exceed 100%, got \(yearlyRate)"
            }
            self.yearlyRate = yearlyRate
        }

        access(all) fun interestRate(creditBalance: UFix128, debitBalance: UFix128): UFix128 {
            return self.yearlyRate
        }
    }

    /// KinkInterestCurve
    ///
    /// A kink-based interest rate curve implementation. The curve has two linear segments:
    /// - Before the optimal utilization ratio (the "kink"): a gentle slope
    /// - After the optimal utilization ratio: a steep slope to discourage over-utilization
    ///
    /// This creates a "kinked" curve that incentivizes maintaining utilization near the
    /// optimal point while heavily penalizing over-utilization to protect protocol liquidity.
    ///
    /// Formula:
    /// - utilization = debitBalance / (creditBalance + debitBalance)
    /// - Before kink (utilization <= optimalUtilization):
    ///   rate = baseRate + (slope1 × utilization / optimalUtilization)
    /// - After kink (utilization > optimalUtilization):
    ///   rate = baseRate + slope1 + (slope2 × excessUtilization)
    ///   where excessUtilization = (utilization - optimalUtilization) / (1 - optimalUtilization)
    ///
    /// @param optimalUtilization The target utilization ratio (e.g., 0.80 for 80%)
    /// @param baseRate The minimum yearly interest rate (e.g., 0.01 for 1% APY)
    /// @param slope1 The total rate increase from 0% to optimal utilization (e.g., 0.04 for 4%)
    /// @param slope2 The total rate increase from optimal to 100% utilization (e.g., 0.60 for 60%)
    access(all) struct KinkInterestCurve: InterestCurve {

        /// The optimal utilization ratio (the "kink" point), e.g., 0.80 = 80%
        access(all) let optimalUtilization: UFix128

        /// The base yearly interest rate applied at 0% utilization
        access(all) let baseRate: UFix128

        /// The slope of the interest curve before the optimal point (gentle slope)
        access(all) let slope1: UFix128

        /// The slope of the interest curve after the optimal point (steep slope)
        access(all) let slope2: UFix128

        init(
            optimalUtilization: UFix128,
            baseRate: UFix128,
            slope1: UFix128,
            slope2: UFix128
        ) {
            pre {
                optimalUtilization >= 0.01:
                    "Optimal utilization must be at least 1%, got \(optimalUtilization)"
                optimalUtilization <= 0.99:
                    "Optimal utilization must be at most 99%, got \(optimalUtilization)"
                slope2 >= slope1:
                    "Slope2 (\(slope2)) must be >= slope1 (\(slope1))"
                baseRate + slope1 + slope2 <= 4.0:
                    "Maximum rate cannot exceed 400%, got \(baseRate + slope1 + slope2)"
            }
            self.optimalUtilization = optimalUtilization
            self.baseRate = baseRate
            self.slope1 = slope1
            self.slope2 = slope2
        }

        access(all) fun interestRate(creditBalance: UFix128, debitBalance: UFix128): UFix128 {
            // If no debt, return base rate
            if debitBalance == 0.0 {
                return self.baseRate
            }

            // Calculate utilization ratio: debitBalance / (creditBalance + debitBalance)
            // Note: totalBalance > 0 is guaranteed since debitBalance > 0 and creditBalance >= 0
            let totalBalance = creditBalance + debitBalance
            let utilization = debitBalance / totalBalance

            // If utilization is below or at the optimal point, use slope1
            if utilization <= self.optimalUtilization {
                // rate = baseRate + (slope1 × utilization / optimalUtilization)
                let utilizationFactor = utilization / self.optimalUtilization
                let slope1Component = self.slope1 * utilizationFactor
                return self.baseRate + slope1Component
            } else {
                // If utilization is above the optimal point, use slope2 for excess
                // excessUtilization = (utilization - optimalUtilization) / (1 - optimalUtilization)
                let excessUtilization = utilization - self.optimalUtilization
                let maxExcess = FlowCreditMarketMath.one - self.optimalUtilization
                let excessFactor = excessUtilization / maxExcess

                // rate = baseRate + slope1 + (slope2 × excessFactor)
                let slope2Component = self.slope2 * excessFactor
                return self.baseRate + self.slope1 + slope2Component
            }
        }
    }

    /// TokenState
    ///
    /// The TokenState struct tracks values related to a single token Type within the Pool.
    access(all) struct TokenState {

        access(EImplementation) var tokenType : Type

        /// The timestamp at which the TokenState was last updated
        access(EImplementation) var lastUpdate: UFix64

        /// The total credit balance for this token, in a specific Pool.
        /// The total credit balance is the sum of balances of all positions with a credit balance (ie. they have lent this token).
        /// In other words, it is the the sum of net deposits among positions which are net creditors in this token.
        access(EImplementation) var totalCreditBalance: UFix128

        /// The total debit balance for this token, in a specific Pool.
        /// The total debit balance is the sum of balances of all positions with a debit balance (ie. they have borrowed this token).
        /// In other words, it is the the sum of net withdrawals among positions which are net debtors in this token.
        access(EImplementation) var totalDebitBalance: UFix128

        /// The index of the credit interest for the related token.
        ///
        /// Interest indices are 18-decimal fixed-point values (see FlowCreditMarketMath) and are stored as UFix128
        /// to maintain precision when converting between scaled and true balances and when compounding.
        access(EImplementation) var creditInterestIndex: UFix128

        /// The index of the debit interest for the related token.
        ///
        /// Interest indices are 18-decimal fixed-point values (see FlowCreditMarketMath) and are stored as UFix128
        /// to maintain precision when converting between scaled and true balances and when compounding.
        access(EImplementation) var debitInterestIndex: UFix128

        /// The per-second interest rate for credit of the associated token.
        ///
        /// For example, if the per-second rate is 1%, this value is 0.01.
        /// Stored as UFix128 to match index precision and avoid cumulative rounding during compounding.
        access(EImplementation) var currentCreditRate: UFix128

        /// The per-second interest rate for debit of the associated token.
        ///
        /// For example, if the per-second rate is 1%, this value is 0.01.
        /// Stored as UFix128 for consistency with indices/rates math.
        access(EImplementation) var currentDebitRate: UFix128

        /// The interest curve implementation used to calculate interest rate
        access(EImplementation) var interestCurve: {InterestCurve}

        /// The annual insurance rate applied to total debit when computing credit interest (default 0.1%)
        access(EImplementation) var insuranceRate: UFix64

        /// Timestamp of the last insurance collection for this token.
        access(EImplementation) var lastInsuranceCollectionTime: UFix64

        /// Swapper used to convert this token to MOET for insurance collection.
        access(EImplementation) var insuranceSwapper: {DeFiActions.Swapper}?

        /// The stability fee rate to calculate stability (default 0.05, 5%).
        access(EImplementation) var stabilityFeeRate: UFix64

        /// Timestamp of the last stability collection for this token.
        access(EImplementation) var lastStabilityFeeCollectionTime: UFix64

        /// Per-position limit fraction of capacity (default 0.05 i.e., 5%)
        access(EImplementation) var depositLimitFraction: UFix64

        /// The rate at which depositCapacity can increase over time. This is a tokens per hour rate,
        /// and should be applied to the depositCapacityCap once an hour.
        access(EImplementation) var depositRate: UFix64

        /// The timestamp of the last deposit capacity update
        access(EImplementation) var lastDepositCapacityUpdate: UFix64

        /// The limit on deposits of the related token
        access(EImplementation) var depositCapacity: UFix64

        /// The upper bound on total deposits of the related token,
        /// limiting how much depositCapacity can reach
        access(EImplementation) var depositCapacityCap: UFix64

        /// Tracks per-user deposit usage for enforcing user deposit limits
        /// Maps position ID -> usage amount (how much of each user's limit has been consumed for this token type)
        access(EImplementation) var depositUsage: {UInt64: UFix64}

        init(
            tokenType: Type,
            interestCurve: {InterestCurve},
            depositRate: UFix64,
            depositCapacityCap: UFix64
        ) {
            self.tokenType = tokenType
            self.lastUpdate = getCurrentBlock().timestamp
            self.totalCreditBalance = 0.0
            self.totalDebitBalance = 0.0
            self.creditInterestIndex = 1.0
            self.debitInterestIndex = 1.0
            self.currentCreditRate = 1.0
            self.currentDebitRate = 1.0
            self.interestCurve = interestCurve
            self.insuranceRate = 0.0
            self.lastInsuranceCollectionTime = getCurrentBlock().timestamp
            self.insuranceSwapper = nil
            self.stabilityFeeRate = 0.05
            self.lastStabilityFeeCollectionTime = getCurrentBlock().timestamp
            self.depositLimitFraction = 0.05
            self.depositRate = depositRate
            self.depositCapacity = depositCapacityCap
            self.depositCapacityCap = depositCapacityCap
            self.depositUsage = {}
            self.lastDepositCapacityUpdate = getCurrentBlock().timestamp
        }

        /// Sets the insurance rate for this token state
        access(EImplementation) fun setInsuranceRate(_ rate: UFix64) {
            self.insuranceRate = rate
        }

        /// Sets the last insurance collection timestamp
        access(EImplementation) fun setLastInsuranceCollectionTime(_ lastInsuranceCollectionTime: UFix64) {
            self.lastInsuranceCollectionTime = lastInsuranceCollectionTime
        }

        /// Sets the swapper used for insurance collection (must swap from this token type to MOET)
        access(EImplementation) fun setInsuranceSwapper(_ swapper: {DeFiActions.Swapper}?) {
            if let swapper = swapper {
                assert(swapper.inType() == self.tokenType, message: "Insurance swapper must accept \(self.tokenType.identifier), not \(swapper.inType().identifier)")
                assert(swapper.outType() == Type<@MOET.Vault>(), message: "Insurance swapper must output MOET")
            }
            self.insuranceSwapper = swapper
        }

        /// Sets the per-deposit limit fraction for this token state
        access(EImplementation) fun setDepositLimitFraction(_ frac: UFix64) {
            self.depositLimitFraction = frac
        }

        /// Sets the deposit rate for this token state after settling the old rate
        /// Argument expressed astokens per hour
        access(EImplementation) fun setDepositRate(_ hourlyRate: UFix64) {
            // settle using old rate if for some reason too much time has passed without regeneration
            self.regenerateDepositCapacity() 
            self.depositRate = hourlyRate
        }

        /// Sets the deposit capacity cap for this token state
        access(EImplementation) fun setDepositCapacityCap(_ cap: UFix64) {
            self.depositCapacityCap = cap
            // If current capacity exceeds the new cap, clamp it to the cap
            if self.depositCapacity > cap {
                self.depositCapacity = cap
            }
            // Reset the last update timestamp to prevent regeneration based on old timestamp
            self.lastDepositCapacityUpdate = getCurrentBlock().timestamp
        }

        /// Sets the stability fee rate for this token state.
        access(EImplementation) fun setStabilityFeeRate(_ rate: UFix64) {
            self.stabilityFeeRate = rate
        }
        
        /// Sets the last stability fee collection timestamp for this token state.
        access(EImplementation) fun setLastStabilityFeeCollectionTime(_ lastStabilityFeeCollectionTime: UFix64) {
            self.lastStabilityFeeCollectionTime = lastStabilityFeeCollectionTime
        }

        /// Calculates the per-user deposit limit cap based on depositLimitFraction * depositCapacityCap
        access(EImplementation) fun getUserDepositLimitCap(): UFix64 {
            return self.depositLimitFraction * self.depositCapacityCap
        }

        /// Decreases deposit capacity by the specified amount and tracks per-user deposit usage
        /// (used when deposits are made)
        access(EImplementation) fun consumeDepositCapacity(_ amount: UFix64, pid: UInt64) {
            assert(
                amount <= self.depositCapacity,
                message: "cannot consume more than available deposit capacity"
            )
            self.depositCapacity = self.depositCapacity - amount
            
            // Track per-user deposit usage for the accepted amount
            let currentUserUsage = self.depositUsage[pid] ?? 0.0
            self.depositUsage[pid] = currentUserUsage + amount

            emit DepositCapacityConsumed(
                tokenType: self.tokenType,
                pid: pid,
                amount: amount,
                remainingCapacity: self.depositCapacity
            )
        }

        /// Sets deposit capacity (used for time-based regeneration)
        access(EImplementation) fun setDepositCapacity(_ capacity: UFix64) {
            self.depositCapacity = capacity
        }

        /// Sets the interest curve for this token state
        /// After updating the curve, also update the interest rates to reflect the new curve
        access(EImplementation) fun setInterestCurve(_ curve: {InterestCurve}) {
            self.interestCurve = curve
            // Update rates immediately to reflect the new curve
            self.updateInterestRates()
        }

        /// Balance update helpers used by core accounting.
        /// All balance changes automatically trigger updateForUtilizationChange()
        /// which recalculates interest rates based on the new utilization ratio.
        /// This ensures rates always reflect the current state of the pool
        /// without requiring manual rate update calls.
        access(EImplementation) fun increaseCreditBalance(by amount: UFix128) {
            self.totalCreditBalance = self.totalCreditBalance + amount
            self.updateForUtilizationChange()
        }

        access(EImplementation) fun decreaseCreditBalance(by amount: UFix128) {
            if amount >= self.totalCreditBalance {
                self.totalCreditBalance = 0.0
            } else {
                self.totalCreditBalance = self.totalCreditBalance - amount
            }
            self.updateForUtilizationChange()
        }

        access(EImplementation) fun increaseDebitBalance(by amount: UFix128) {
            self.totalDebitBalance = self.totalDebitBalance + amount
            self.updateForUtilizationChange()
        }

        access(EImplementation) fun decreaseDebitBalance(by amount: UFix128) {
            if amount >= self.totalDebitBalance {
                self.totalDebitBalance = 0.0
            } else {
                self.totalDebitBalance = self.totalDebitBalance - amount
            }
            self.updateForUtilizationChange()
        }

        /// Updates the totalCreditBalance by the provided amount
        /// TODO(jord): unused
        access(EImplementation) fun updateCreditBalance(amount: Int256) {
            // temporary cast the credit balance to a signed value so we can add/subtract
            let adjustedBalance = Int256(self.totalCreditBalance) + amount
            // Do not silently clamp: underflow indicates a serious accounting error
            assert(
                adjustedBalance >= 0,
                message: "totalCreditBalance underflow"
            )
            self.totalCreditBalance = UFix128(adjustedBalance)
            self.updateForUtilizationChange()
        }

        /// TODO(jord): unused
        access(EImplementation) fun updateDebitBalance(amount: Int256) {
            // temporary cast the debit balance to a signed value so we can add/subtract
            let adjustedBalance = Int256(self.totalDebitBalance) + amount
            // Do not silently clamp: underflow indicates a serious accounting error
            assert(
                adjustedBalance >= 0,
                message: "totalDebitBalance underflow"
            )
            self.totalDebitBalance = UFix128(adjustedBalance)
            self.updateForUtilizationChange()
        }

        // Updates the credit and debit interest index for this token, accounting for time since the last update.
        access(EImplementation) fun updateInterestIndices() {
            let currentTime = getCurrentBlock().timestamp
            let dt = currentTime - self.lastUpdate

            // No time elapsed or already at cap → nothing to do
            if dt <= 0.0 {
                return
            }

            // Update interest indices (dt > 0 ensures sensible compounding)
            self.creditInterestIndex = FlowCreditMarket.compoundInterestIndex(
                oldIndex: self.creditInterestIndex,
                perSecondRate: self.currentCreditRate,
                elapsedSeconds: dt
            )
            self.debitInterestIndex = FlowCreditMarket.compoundInterestIndex(
                oldIndex: self.debitInterestIndex,
                perSecondRate: self.currentDebitRate,
                elapsedSeconds: dt
            )

            // Record the moment we accounted for
            self.lastUpdate = currentTime
        }

        /// Regenerates deposit capacity over time based on depositRate
        /// Note: dt should be calculated before updateInterestIndices() updates lastUpdate
        /// When capacity regenerates, all user deposit usage is reset for this token type
        access(EImplementation) fun regenerateDepositCapacity() {
            let currentTime = getCurrentBlock().timestamp
            let dt = currentTime - self.lastDepositCapacityUpdate
            let hourInSeconds = 3600.0
            if dt >= hourInSeconds { // 1 hour
                let multiplier = dt / hourInSeconds
                let oldCap = self.depositCapacityCap
                let newDepositCapacityCap = self.depositRate * multiplier + self.depositCapacityCap

                self.depositCapacityCap = newDepositCapacityCap

                // Set the deposit capacity to the new deposit capacity cap, i.e. regenerate the capacity
                self.setDepositCapacity(newDepositCapacityCap)
                
                // Regenerate user usage for this token type as well
                self.depositUsage = {}

                self.lastDepositCapacityUpdate = currentTime

                emit DepositCapacityRegenerated(
                    tokenType: self.tokenType,
                    oldCapacityCap: oldCap,
                    newCapacityCap: newDepositCapacityCap
                )
            }
        }

        // Deposit limit function
        // Rationale: cap per-deposit size to a fraction of the time-based
        // depositCapacity so a single large deposit cannot monopolize capacity.
        // Excess is queued and drained in chunks (see asyncUpdatePosition),
        // enabling fair throughput across many deposits in a block. The 5%
        // fraction is conservative and can be tuned by protocol parameters.
        access(EImplementation) fun depositLimit(): UFix64 {
            return self.depositCapacity * self.depositLimitFraction
        }


        access(EImplementation) fun updateForTimeChange() {
            self.updateInterestIndices()
            self.regenerateDepositCapacity()
        }

        /// Called after any action that changes utilization (deposits, withdrawals, borrows, repays).
        /// Recalculates interest rates based on the new credit/debit balance ratio.
        access(EImplementation) fun updateForUtilizationChange() {
            self.updateInterestRates()
        }

        access(EImplementation) fun updateInterestRates() {
            let debitRate = self.interestCurve.interestRate(
                creditBalance: self.totalCreditBalance,
                debitBalance: self.totalDebitBalance
            )
            let insuranceRate = UFix128(self.insuranceRate)
            let stabilityFeeRate = UFix128(self.stabilityFeeRate)

            var creditRate: UFix128 = 0.0
            // Total protocol cut as a percentage of debit interest income
            let protocolFeeRate = insuranceRate + stabilityFeeRate

            // Two calculation paths based on curve type:
            // 1. FixedRateInterestCurve: simple spread model (creditRate = debitRate * (1 - protocolFeeRate))
            //    Used for stable assets like MOET where rates are governance-controlled
            // 2. KinkInterestCurve (and others): reserve factor model
            //    Insurance and stability are percentages of interest income, not a fixed spread
            // TODO(jord): seems like InterestCurve abstraction could be improved if we need to check specific types here.
            if self.interestCurve.getType() == Type<FlowCreditMarket.FixedRateInterestCurve>() {
                // FixedRate path: creditRate = debitRate * (1 - protocolFeeRate))
                // This provides a fixed, predictable spread between borrower and lender rates
                creditRate = debitRate * (1.0 - protocolFeeRate) 
            } else {
                // KinkCurve path (and any other curves): reserve factor model
                // protocolFeeAmount = debitIncome * protocolFeeRate (percentage of income)
                // creditRate = (debitIncome - protocolFeeAmount) / totalCreditBalance
                let debitIncome = self.totalDebitBalance * debitRate
                let protocolFeeAmount = debitIncome * protocolFeeRate

                if self.totalCreditBalance > 0.0 {
                    creditRate = (debitIncome - protocolFeeAmount) / self.totalCreditBalance
                }
            }

            self.currentCreditRate = FlowCreditMarket.perSecondInterestRate(yearlyRate: creditRate)
            self.currentDebitRate = FlowCreditMarket.perSecondInterestRate(yearlyRate: debitRate)
        }

        /// Collects insurance by withdrawing from reserves and swapping to MOET.
        /// The insurance amount is calculated based on the insurance rate applied to the total debit balance over the time elapsed.
        /// This should be called periodically (e.g., when updateInterestRates is called) to accumulate the insurance fund.
        /// CAUTION: This function will panic if no insuranceSwapper is provided.
        ///
        /// @param reserveVault: The reserve vault for this token type to withdraw insurance from
        /// @return: A MOET vault containing the collected insurance funds, or nil if no collection occurred
        access(EImplementation) fun collectInsurance(
            reserveVault: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}
        ): @MOET.Vault? {
            let currentTime = getCurrentBlock().timestamp

            // If insuranceRate is 0.0 configured, skip collection but update the last insurance collection time
            if self.insuranceRate == 0.0 {
                self.setLastInsuranceCollectionTime(currentTime)
                return nil
            }

            // Calculate accrued insurance amount based on time elapsed since last collection
            let timeElapsed = currentTime - self.lastInsuranceCollectionTime
            
            // If no time has elapsed, nothing to collect
            if timeElapsed <= 0.0 {
                return nil
            }

            // Insurance amount is a percentage of debit income
            // debitIncome = debitBalance * (curentDebitRate ^ time_elapsed - 1.0)
            let debitIncome = self.totalDebitBalance * (FlowCreditMarketMath.powUFix128(self.currentDebitRate, timeElapsed) - 1.0)
            let insuranceAmount = debitIncome * UFix128(self.insuranceRate)
            let insuranceAmountUFix64 = FlowCreditMarketMath.toUFix64RoundDown(insuranceAmount)

            // If calculated amount is zero, skip collection but update timestamp
            if insuranceAmountUFix64 == 0.0 {
                self.setLastInsuranceCollectionTime(currentTime)
                return nil
            }
            
            // Check if we have enough balance in reserves
            if reserveVault.balance == 0.0 {
                self.setLastInsuranceCollectionTime(currentTime)
                return nil
            }

            // Withdraw insurance amount from reserves (use available balance if less than calculated)
            let amountToCollect = insuranceAmountUFix64 > reserveVault.balance ? reserveVault.balance : insuranceAmountUFix64
            var insuranceVault <- reserveVault.withdraw(amount: amountToCollect)

			let insuranceSwapper = self.insuranceSwapper ?? panic("missing insurance swapper")

            // Validate swapper input and output types (input and output types are already validated when swapper is set)
            assert(insuranceSwapper.inType() == reserveVault.getType(), message: "Insurance swapper input type must be same as reserveVault")
            assert(insuranceSwapper.outType() == Type<@MOET.Vault>(), message: "Insurance swapper must output MOET")

            // Get quote and perform swap
            let quote = insuranceSwapper.quoteOut(forProvided: amountToCollect, reverse: false)
            var moetVault <- insuranceSwapper.swap(quote: quote, inVault: <-insuranceVault) as! @MOET.Vault

            // Update last collection time
            self.setLastInsuranceCollectionTime(currentTime)

            // Return the MOET vault for the caller to deposit
            return <-moetVault
        }

        /// Collects stability funds by withdrawing from reserves.
        /// The stability amount is calculated based on the stability rate applied to the total debit balance over the time elapsed.
        /// This should be called periodically (e.g., when updateInterestRates is called) to accumulate the stability fund.
        ///
        /// @param reserveVault: The reserve vault for this token type to withdraw stability amount from
        /// @return: A token type vault containing the collected stability funds, or nil if no collection occurred
        access(EImplementation) fun collectStability(
            reserveVault: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}
        ): @{FungibleToken.Vault}? {
            let currentTime = getCurrentBlock().timestamp

            // If stabilityFeeRate is 0.0 configured, skip collection but update the last stability collection time
            if self.stabilityFeeRate == 0.0 {
                self.setLastStabilityFeeCollectionTime(currentTime)
                return nil
            }

            // Calculate accrued stability amount based on time elapsed since last collection
            let timeElapsed = currentTime - self.lastStabilityFeeCollectionTime

            // If no time has elapsed, nothing to collect
            if timeElapsed <= 0.0 {
                return nil
            }

            let stabilityFeeRate = UFix128(self.stabilityFeeRate)

            // Calculate stability amount: is a percentage of debit income
            // debitIncome = debitBalance * (curentDebitRate ^ time_elapsed - 1.0)
            let interestIncome = self.totalDebitBalance * (FlowCreditMarketMath.powUFix128(self.currentDebitRate, timeElapsed) - 1.0)
            let stabilityAmount = interestIncome * stabilityFeeRate
            let stabilityAmountUFix64 = FlowCreditMarketMath.toUFix64RoundDown(stabilityAmount)

            // If calculated amount is zero or negative, skip collection but update timestamp
            if stabilityAmountUFix64 == 0.0 {
                self.setLastStabilityFeeCollectionTime(currentTime)
                return nil
            }

            // Check if we have enough balance in reserves
            if reserveVault.balance == 0.0 {
                self.setLastStabilityFeeCollectionTime(currentTime)
                return nil
            }

            let reserveVaultBalance = reserveVault.balance
            // Withdraw stability amount from reserves (use available balance if less than calculated)
            let amountToCollect = stabilityAmountUFix64 > reserveVaultBalance ? reserveVaultBalance : stabilityAmountUFix64
            let stabilityVault <- reserveVault.withdraw(amount: amountToCollect)

            // Update last collection time
            self.setLastStabilityFeeCollectionTime(currentTime)

            // Return the vault for the caller to deposit
            return <-stabilityVault
        }
    }

    /// Risk parameters for a token used in effective collateral/debt computations.
    /// The collateral and borrow factors are fractional values which represent a discount to the "true/market" value of the token.
    /// The size of this discount indicates a subjective assessment of risk for the token.
    /// The difference between the effective value and "true" value represents the safety buffer available to prevent loss.
    /// - collateralFactor: the factor used to derive effective collateral
    /// - borrowFactor: the factor used to derive effective debt
    /// - liquidationBonus: premium applied to liquidations to incentivize repayors
    access(all) struct RiskParams {
        /// The factor (Fc) used to determine effective collateral, in the range [0, 1]
        /// See FlowCreditMarket.effectiveCollateral for additional detail.
        access(all) let collateralFactor: UFix128
        /// The factor (Fd) used to determine effective debt, in the range [0, 1]
        /// See FlowCreditMarket.effectiveDebt for additional detail.
        access(all) let borrowFactor: UFix128

        /// Bonus expressed as fractional rate, e.g. 0.05 for 5%
        access(all) let liquidationBonus: UFix128

        init(
            collateralFactor: UFix128,
            borrowFactor: UFix128,
            liquidationBonus: UFix128
        ) {
            pre {
                collateralFactor <= 1.0: "collateral factor must be <=1"
                borrowFactor <= 1.0: "borrow factor must be <=1"
            }
            self.collateralFactor = collateralFactor
            self.borrowFactor = borrowFactor
            self.liquidationBonus = liquidationBonus
        }
    }

    /// Immutable snapshot of token-level data required for pure math operations
    access(all) struct TokenSnapshot {
        access(all) let price: UFix128
        access(all) let creditIndex: UFix128
        access(all) let debitIndex: UFix128
        access(all) let risk: RiskParams

        init(
            price: UFix128,
            credit: UFix128,
            debit: UFix128,
            risk: RiskParams
        ) {
            self.price = price
            self.creditIndex = credit
            self.debitIndex = debit
            self.risk = risk
        }

        /// Returns the effective debt (denominated in $) for the given debit balance of this snapshot's token.
        /// See FlowCreditMarket.effectiveDebt for additional details.
        access(all) view fun effectiveDebt(debitBalance: UFix128): UFix128 {
            return FlowCreditMarket.effectiveDebt(debit: debitBalance, price: self.price, borrowFactor: self.risk.borrowFactor)
        }

        /// Returns the effective collateral (denominated in $) for the given credit balance of this snapshot's token.
        /// See FlowCreditMarket.effectiveCollateral for additional details.
        access(all) view fun effectiveCollateral(creditBalance: UFix128): UFix128 {
            return FlowCreditMarket.effectiveCollateral(credit: creditBalance, price: self.price, collateralFactor: self.risk.collateralFactor)
        }
    }

    /// Copy-only representation of a position used by pure math (no storage refs)
    access(all) struct PositionView {
        /// Set of all non-zero balances in the position.
        /// If the position does not have a balance for a supported token, no entry for that token exists in this map.
        access(all) let balances: {Type: InternalBalance}
        /// Set of all token snapshots for which this position has a non-zero balance.
        /// If the position does not have a balance for a supported token, no entry for that token exists in this map.
        access(all) let snapshots: {Type: TokenSnapshot}
        access(all) let defaultToken: Type
        access(all) let minHealth: UFix128
        access(all) let maxHealth: UFix128

        init(
            balances: {Type: InternalBalance},
            snapshots: {Type: TokenSnapshot},
            defaultToken: Type,
            min: UFix128,
            max: UFix128
        ) {
            self.balances = balances
            self.snapshots = snapshots
            self.defaultToken = defaultToken
            self.minHealth = min
            self.maxHealth = max
        }

        /// Returns the true balance of the given token in this position, accounting for interest.
        /// Returns balance 0.0 if the position has no balance stored for the given token.
        access(all) view fun trueBalance(ofToken: Type): UFix128 {
            if let balance = self.balances[ofToken] {
                if let tokenSnapshot = self.snapshots[ofToken] {
                    switch balance.direction {
                    case BalanceDirection.Debit:
                        return FlowCreditMarket.scaledBalanceToTrueBalance(
                            balance.scaledBalance, interestIndex: tokenSnapshot.debitIndex)
                    case BalanceDirection.Credit:
                        return FlowCreditMarket.scaledBalanceToTrueBalance(
                            balance.scaledBalance, interestIndex: tokenSnapshot.creditIndex)
                    }
                    panic("unreachable")
                }
            } 
            // If the token doesn't exist in the position, the balance is 0
            return 0.0
        }
    }

    // PURE HELPERS -------------------------------------------------------------

    /// Returns the effective collateral (denominated in $) for the given credit balance of some token T.
    /// Effective Collateral is defined:
    ///   Ce = (Nc)(Pc)(Fc)
    /// Where:
    /// Ce = Effective Collateral 
    /// Nc = Number of Collateral Tokens
    /// Pc = Collateral Token Price
    /// Fc = Collateral Factor
    ///
    /// @param credit           The credit balance of the position for token T.
    /// @param price            The price of token T ($/T).
    /// @param collateralFactor The collateral factor for token T (see RiskParams for details).
    access(all) view fun effectiveCollateral(credit: UFix128, price: UFix128, collateralFactor: UFix128): UFix128 {
        return (credit * price) * collateralFactor
    }

    /// Returns the effective debt (denominated in $) for the given debit balance of some token T.
    /// Effective Debt is defined:
    ///   De = (Nd)(Pd)(Fd)
    /// Where:
    /// De = Effective Debt 
    /// Nd = Number of Debt Tokens
    /// Pd = Debt Token Price
    /// Fd = Borrow Factor
    ///
    /// @param debit       The debit balance of the position for token T.
    /// @param price       The price of token T ($/T).
    /// @param borowFactor The borrow factor for token T (see RiskParams for details).
    access(all) view fun effectiveDebt(debit: UFix128, price: UFix128, borrowFactor: UFix128): UFix128 {
        return (debit * price) / borrowFactor
    }

    /// Computes health = totalEffectiveCollateral / totalEffectiveDebt (∞ when debt == 0)
    // TODO: return BalanceSheet, this seems like a dupe of _getUpdatedBalanceSheet
    access(all) view fun healthFactor(view: PositionView): UFix128 {
        // TODO: this logic partly duplicates BalanceSheet construction in _getUpdatedBalanceSheet
        // This function differs in that it does not read any data from a Pool resource. Consider consolidating the two implementations.
        var effectiveCollateralTotal: UFix128 = 0.0
        var effectiveDebtTotal: UFix128 = 0.0

        for tokenType in view.balances.keys {
            let balance = view.balances[tokenType]!
            let snap = view.snapshots[tokenType]!

            switch balance.direction {
                case BalanceDirection.Credit:
                    let trueBalance = FlowCreditMarket.scaledBalanceToTrueBalance(
                        balance.scaledBalance,
                        interestIndex: snap.creditIndex
                    )
                    effectiveCollateralTotal = effectiveCollateralTotal
                        + snap.effectiveCollateral(creditBalance: trueBalance)

                case BalanceDirection.Debit:
                    let trueBalance = FlowCreditMarket.scaledBalanceToTrueBalance(
                        balance.scaledBalance,
                        interestIndex: snap.debitIndex
                    )
                    effectiveDebtTotal = effectiveDebtTotal
                        + snap.effectiveDebt(debitBalance: trueBalance)
            }
        }
        return FlowCreditMarket.healthComputation(
            effectiveCollateral: effectiveCollateralTotal,
            effectiveDebt: effectiveDebtTotal
        )
    }

    /// Amount of `withdrawSnap` token that can be withdrawn while staying ≥ targetHealth
    access(all) view fun maxWithdraw(
        view: PositionView,
        withdrawSnap: TokenSnapshot,
        withdrawBal: InternalBalance?,
        targetHealth: UFix128
    ): UFix128 {
        let preHealth = FlowCreditMarket.healthFactor(view: view)
        if preHealth <= targetHealth {
            return 0.0
        }

        // TODO: this logic partly duplicates BalanceSheet construction in _getUpdatedBalanceSheet
        // This function differs in that it does not read any data from a Pool resource. Consider consolidating the two implementations.
        var effectiveCollateralTotal: UFix128 = 0.0
        var effectiveDebtTotal: UFix128 = 0.0

        for tokenType in view.balances.keys {
            let balance = view.balances[tokenType]!
            let snap = view.snapshots[tokenType]!

            switch balance.direction {
                case BalanceDirection.Credit:
                    let trueBalance = FlowCreditMarket.scaledBalanceToTrueBalance(
                        balance.scaledBalance,
                        interestIndex: snap.creditIndex
                    )
                    effectiveCollateralTotal = effectiveCollateralTotal
                        + snap.effectiveCollateral(creditBalance: trueBalance)

                case BalanceDirection.Debit:
                    let trueBalance = FlowCreditMarket.scaledBalanceToTrueBalance(
                        balance.scaledBalance,
                        interestIndex: snap.debitIndex
                    )
                    effectiveDebtTotal = effectiveDebtTotal
                        + snap.effectiveDebt(debitBalance: trueBalance)
            }
        }

        let collateralFactor = withdrawSnap.risk.collateralFactor
        let borrowFactor = withdrawSnap.risk.borrowFactor

        if withdrawBal == nil || withdrawBal!.direction == BalanceDirection.Debit {
            // withdrawing increases debt
            let numerator = effectiveCollateralTotal
            let denominatorTarget = numerator / targetHealth
            let deltaDebt = denominatorTarget > effectiveDebtTotal
                ? denominatorTarget - effectiveDebtTotal
                : 0.0 as UFix128
            return (deltaDebt * borrowFactor) / withdrawSnap.price
        } else {
            // withdrawing reduces collateral
            let trueBalance = FlowCreditMarket.scaledBalanceToTrueBalance(
                withdrawBal!.scaledBalance,
                interestIndex: withdrawSnap.creditIndex
            )
            let maxPossible = trueBalance
            let requiredCollateral = effectiveDebtTotal * targetHealth
            if effectiveCollateralTotal <= requiredCollateral {
                return 0.0
            }
            let deltaCollateralEffective = effectiveCollateralTotal - requiredCollateral
            let deltaTokens = (deltaCollateralEffective / collateralFactor) / withdrawSnap.price
            return deltaTokens > maxPossible ? maxPossible : deltaTokens
        }
    }

    /// Pool
    ///
    /// A Pool is the primary logic for protocol operations. It contains the global state of all positions,
    /// credit and debit balances for each supported token type, and reserves as they are deposited to positions.
    access(all) resource Pool {

        /// Enable or disable verbose contract logging for debugging.
        access(self) var debugLogging: Bool

        /// Global state for tracking each token
        access(self) var globalLedger: {Type: TokenState}

        /// Individual user positions
        access(self) var positions: @{UInt64: InternalPosition}

        /// The actual reserves of each token
        access(self) var reserves: @{Type: {FungibleToken.Vault}}

        /// The insurance fund vault storing MOET tokens collected from insurance rates
        access(self) var insuranceFund: @MOET.Vault

        /// Auto-incrementing position identifier counter
        access(self) var nextPositionID: UInt64

        /// The default token type used as the "unit of account" for the pool.
        access(self) let defaultToken: Type

        /// A price oracle that will return the price of each token in terms of the default token.
        access(self) var priceOracle: {DeFiActions.PriceOracle}

        /// Together with borrowFactor, collateralFactor determines borrowing limits for each token.
        ///
        /// When determining the withdrawable loan amount, the value of the token (provided by the PriceOracle)
        /// is multiplied by the collateral factor.
        ///
        /// The total "effective collateral" for a position is the value of each token deposited to the position
        /// multiplied by its collateral factor.
        access(self) var collateralFactor: {Type: UFix64}

        /// Together with collateralFactor, borrowFactor determines borrowing limits for each token.
        ///
        /// The borrowFactor determines how much of a position's "effective collateral" can be borrowed against as a
        /// percentage between 0.0 and 1.0
        access(self) var borrowFactor: {Type: UFix64}

        /// Per-token liquidation bonus fraction (e.g., 0.05 for 5%)
        /// TODO(jord): we want to keep this logic but set it to 0 initially
        access(self) var liquidationBonus: {Type: UFix64}

        /// The count of positions to update per asynchronous update
        access(self) var positionsProcessedPerCallback: UInt64

        /// The stability fund vaults storing tokens collected from stability fee rates.
        access(self) var stabilityFunds: @{Type: {FungibleToken.Vault}}

        /// Position update queue to be processed as an asynchronous update
        access(EImplementation) var positionsNeedingUpdates: [UInt64]

        /// Deprecated: This field is unused and should be removed in the next contract re-deployment
        access(EImplementation) var version: UInt64

        /// Liquidation target health and controls (global)

        /// The target health factor when liquidating a position, which limits how much collateral can be liquidated.
        /// After a liquidation, the position's health factor must be less than or equal to this target value.
        access(self) var liquidationTargetHF: UFix128
        /// Whether liquidations are currently paused
        access(self) var liquidationsPaused: Bool
        /// Period (s) following liquidation unpause in which liquidations are still not allowed
        access(self) var liquidationWarmupSec: UInt64
        /// Time this pool most recently had liquidations paused
        access(self) var lastUnpausedAt: UInt64?

        /// Deprecated: Unused field, but cannot be removed without contract update
        access(self) var protocolLiquidationFeeBps: UInt16

        // TODO(jord): figure out how to reference dex https://github.com/onflow/FlowCreditMarket/issues/94
        //  - either need to redeploy contract to create new dex field
        //  - or need to revert to allowlist pattern and pass in swapper instances (I worry about security of this option)
        //  - also to make allowlist pattern work with automated liquidation, initiator of this automation will need actual handle on a dex in order to pass it to FCM 

        /// Allowlist of permitted DeFiActions Swapper types for DEX liquidations
        /// TODO: unused! To remove, must re-deploy existing contracts
        access(self) var allowedSwapperTypes: {Type: Bool}

        /// A trusted DEX (or set of DEXes) used by FCM as a pricing oracle and trading counterparty for liquidations.
        /// The SwapperProvider implementation MUST return a Swapper for all possible (ordered) pairs of supported tokens.
        /// If [X1, X2, ..., Xn] is the set of supported tokens, then the SwapperProvider must return a Swapper for all pairs: 
        ///   (Xi, Xj) where i∈[1,n], j∈[1,n], i≠j
        ///
        /// FCM does not attempt to construct multi-part paths (using multiple Swappers) or compare prices across Swappers.
        /// It relies directly on the Swapper's returned by the configured SwapperProvider.
        access(self) let dex: {DeFiActions.SwapperProvider}

        /// Max allowed deviation in basis points between DEX-implied price and oracle price
        access(self) var dexOracleDeviationBps: UInt16

        /// Max slippage allowed in basis points for DEX liquidations
        /// TODO(jord): revisit this. Is this ever necessary if we are also checking dexOracleDeviationBps? Do we want both a spot price check and a slippage from spot price check?
        /// TODO: unused! To remove, must re-deploy existing contracts
        access(self) var dexMaxSlippageBps: UInt64

        /// Max route hops allowed for DEX liquidations
        /// TODO: unused! To remove, must re-deploy existing contracts
        access(self) var dexMaxRouteHops: UInt64

        init(
        	defaultToken: Type,
        	priceOracle: {DeFiActions.PriceOracle},
        	dex: {DeFiActions.SwapperProvider}
        ) {
            pre {
                priceOracle.unitOfAccount() == defaultToken:
                    "Price oracle must return prices in terms of the default token"
            }

            self.version = 0 // deprecated
            self.debugLogging = false
            self.globalLedger = {
                defaultToken: TokenState(
                    tokenType: defaultToken,
                    interestCurve: FixedRateInterestCurve(yearlyRate: 0.0),
                    depositRate: 1_000_000.0,        // Default: no rate limiting for default token
                    depositCapacityCap: 1_000_000.0  // Default: high capacity cap
                )
            }
            self.positions <- {}
            self.reserves <- {}
            self.insuranceFund <- MOET.createEmptyVault(vaultType: Type<@MOET.Vault>())
            self.stabilityFunds <- {}
            self.defaultToken = defaultToken
            self.priceOracle = priceOracle
            self.collateralFactor = {defaultToken: 1.0}
            self.borrowFactor = {defaultToken: 1.0}
            self.liquidationBonus = {defaultToken: 0.05}
            self.nextPositionID = 0
            self.positionsNeedingUpdates = []
            self.positionsProcessedPerCallback = 100
            self.liquidationTargetHF = 1.05
            self.liquidationsPaused = false
            self.liquidationWarmupSec = 300
            self.lastUnpausedAt = nil
            self.protocolLiquidationFeeBps = 0
            self.allowedSwapperTypes = {}
            self.dex = dex
            self.dexOracleDeviationBps = 300 // 3% default
            self.dexMaxSlippageBps = 100
            self.dexMaxRouteHops = 3

            // The pool starts with an empty reserves map.
            // Vaults will be created when tokens are first deposited.
        }

        access(self) fun _assertLiquidationsActive() {
            pre {
                !self.liquidationsPaused:
                    "Liquidations paused"
            }
            if let lastUnpausedAt = self.lastUnpausedAt {
                let now = UInt64(getCurrentBlock().timestamp)
                assert(
                    now >= lastUnpausedAt + self.liquidationWarmupSec,
                    message: "Liquidations in warm-up period"
                )
            }
        }

        ///////////////
        // GETTERS
        ///////////////

        /// Returns an array of the supported token Types
        access(all) view fun getSupportedTokens(): [Type] {
            return self.globalLedger.keys
        }

        /// Returns whether a given token Type is supported or not
        access(all) view fun isTokenSupported(tokenType: Type): Bool {
            return self.globalLedger[tokenType] != nil
        } 

        /// Returns the current balance of the stability fund for a given token type.
        /// Returns nil if the token type is not supported.
        access(all) view fun getStabilityFundBalance(tokenType: Type): UFix64? {
            if let fundRef = &self.stabilityFunds[tokenType] as &{FungibleToken.Vault}? {
                return fundRef.balance
            }
            
            return nil
        }

        /// Returns the stability fee rate for a given token type.
        /// Returns nil if the token type is not supported.
        access(all) view fun getStabilityFeeRate(tokenType: Type): UFix64? {
            if let tokenState = self.globalLedger[tokenType] {
                return tokenState.stabilityFeeRate
            }

            return nil
        }

        /// Returns the timestamp of the last stability collection for a given token type.
        /// Returns nil if the token type is not supported.
        access(all) view fun getLastStabilityCollectionTime(tokenType: Type): UFix64? {
            if let tokenState = self.globalLedger[tokenType] {
                return tokenState.lastStabilityFeeCollectionTime
            }

            return nil
        }

        /// Returns whether an insurance swapper is configured for a given token type
        access(all) view fun isInsuranceSwapperConfigured(tokenType: Type): Bool {
            if let tokenState = self.globalLedger[tokenType] {
                return tokenState.insuranceSwapper != nil
            }
            return false
        }

        /// Returns the timestamp of the last insurance collection for a given token type
        /// Returns nil if the token type is not supported
        access(all) view fun getLastInsuranceCollectionTime(tokenType: Type): UFix64? {
            if let tokenState = self.globalLedger[tokenType] {
                return tokenState.lastInsuranceCollectionTime
            }
            return nil
        }

        /// Returns current liquidation parameters
        access(all) fun getLiquidationParams(): FlowCreditMarket.LiquidationParamsView {
            return FlowCreditMarket.LiquidationParamsView(
                targetHF: self.liquidationTargetHF,
                paused: self.liquidationsPaused,
                warmupSec: self.liquidationWarmupSec,
                lastUnpausedAt: self.lastUnpausedAt,
                triggerHF: 1.0,
            )
        }

        /// Returns Oracle-DEX guards and allowlists for frontends/keepers
        access(all) fun getDexLiquidationConfig(): {String: AnyStruct} {
            let allowed: [String] = []
            for t in self.allowedSwapperTypes.keys {
                allowed.append(t.identifier)
            }
            return {
                "dexOracleDeviationBps": self.dexOracleDeviationBps,
                "allowedSwappers": allowed,
                "dexMaxSlippageBps": self.dexMaxSlippageBps,
                "dexMaxRouteHops": self.dexMaxRouteHops // informational; enforcement is left to swapper implementations
            }
        }

        /// Returns true if the position is under the global liquidation trigger (health < 1.0)
        access(all) fun isLiquidatable(pid: UInt64): Bool {
            let health = self.positionHealth(pid: pid)
            return health < 1.0
        }

        /// Returns the current reserve balance for the specified token type.
        access(all) view fun reserveBalance(type: Type): UFix64 {
            let vaultRef = &self.reserves[type] as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?
            return vaultRef?.balance ?? 0.0
        }

        /// Returns the balance of the MOET insurance fund
        access(all) view fun insuranceFundBalance(): UFix64 {
            return self.insuranceFund.balance
        }

        /// Returns the insurance rate for a given token type
        access(all) view fun getInsuranceRate(tokenType: Type): UFix64? {
            if let tokenState = self.globalLedger[tokenType] {
                return tokenState.insuranceRate
            }
            
            return nil
        }

        /// Returns a reference to the reserve vault for the given type, if the token type is supported.
        /// If no reserve vault exists yet, and the token type is supported, the reserve vault is created.
        access(self) fun _borrowOrCreateReserveVault(type: Type): &{FungibleToken.Vault} {
            pre {
                self.isTokenSupported(tokenType: type): "Cannot borrow reserve for unsupported token \(type.identifier)"
            }
            if self.reserves[type] == nil {
                self.reserves[type] <-! DeFiActionsUtils.getEmptyVault(type)
            }
            let vaultRef = &self.reserves[type] as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?
            return vaultRef!
        }

        /// Returns a position's balance available for withdrawal of a given Vault type.
        /// Phase 0 refactor: compute via pure helpers using a PositionView and TokenSnapshot for the base path.
        /// When `pullFromTopUpSource` is true and a topUpSource exists, preserve deposit-assisted semantics.
        access(all) fun availableBalance(pid: UInt64, type: Type, pullFromTopUpSource: Bool): UFix64 {
            if self.debugLogging {
                log("    [CONTRACT] availableBalance(pid: \(pid), type: \(type.contractName!), pullFromTopUpSource: \(pullFromTopUpSource))")
            }
            let position = self._borrowPosition(pid: pid)

            if pullFromTopUpSource {
                if let topUpSource = position.topUpSource {
                    let sourceType = topUpSource.getSourceType()
                    let sourceAmount = topUpSource.minimumAvailable()
                    if self.debugLogging {
                        log("    [CONTRACT] Calling to fundsAvailableAboveTargetHealthAfterDepositing with sourceAmount \(sourceAmount) and targetHealth \(position.minHealth)")
                    }

                    return self.fundsAvailableAboveTargetHealthAfterDepositing(
                        pid: pid,
                        withdrawType: type,
                        targetHealth: position.minHealth,
                        depositType: sourceType,
                        depositAmount: sourceAmount
                    )
                }
            }

            let view = self.buildPositionView(pid: pid)

            // Build a TokenSnapshot for the requested withdraw type (may not exist in view.snapshots)
            let tokenState = self._borrowUpdatedTokenState(type: type)
            let snap = FlowCreditMarket.TokenSnapshot(
                price: UFix128(self.priceOracle.price(ofToken: type)!),
                credit: tokenState.creditInterestIndex,
                debit: tokenState.debitInterestIndex,
                risk: FlowCreditMarket.RiskParams(
                    collateralFactor: UFix128(self.collateralFactor[type]!),
                    borrowFactor: UFix128(self.borrowFactor[type]!),
                    liquidationBonus: UFix128(self.liquidationBonus[type]!)
                )
            )

            let withdrawBal = view.balances[type]
            let uintMax = FlowCreditMarket.maxWithdraw(
                view: view,
                withdrawSnap: snap,
                withdrawBal: withdrawBal,
                targetHealth: view.minHealth
            )
            return FlowCreditMarketMath.toUFix64Round(uintMax)
        }

        /// Returns the health of the given position, which is the ratio of the position's effective collateral
        /// to its debt as denominated in the Pool's default token.
        /// "Effective collateral" means the value of each credit balance times the liquidation threshold
        /// for that token, i.e. the maximum borrowable amount
        // TODO: make this output enumeration of effective debts/collaterals (or provide option that does)
        access(all) fun positionHealth(pid: UInt64): UFix128 {
            let position = self._borrowPosition(pid: pid)

            // Get the position's collateral and debt values in terms of the default token.
            var effectiveCollateral: UFix128 = 0.0
            var effectiveDebt: UFix128 = 0.0

            for type in position.balances.keys {
                let balance = position.balances[type]!
                let tokenState = self._borrowUpdatedTokenState(type: type)

                let collateralFactor = UFix128(self.collateralFactor[type]!)
                let borrowFactor = UFix128(self.borrowFactor[type]!)
                let price = UFix128(self.priceOracle.price(ofToken: type)!)
                switch balance.direction {
                    case BalanceDirection.Credit:
                        let trueBalance = FlowCreditMarket.scaledBalanceToTrueBalance(
                            balance.scaledBalance,
                            interestIndex: tokenState.creditInterestIndex
                        )

                        let value = price * trueBalance
                        let effectiveCollateralValue = value * collateralFactor
                        effectiveCollateral = effectiveCollateral + effectiveCollateralValue

                    case BalanceDirection.Debit:
                        let trueBalance = FlowCreditMarket.scaledBalanceToTrueBalance(
                            balance.scaledBalance,
                            interestIndex: tokenState.debitInterestIndex
                        )

                        let value = price * trueBalance
                        let effectiveDebtValue = value / borrowFactor
                        effectiveDebt = effectiveDebt + effectiveDebtValue
                }
            }

            // Calculate the health as the ratio of collateral to debt.
            return FlowCreditMarket.healthComputation(
                effectiveCollateral: effectiveCollateral,
                effectiveDebt: effectiveDebt
            )
        }

        /// Returns the quantity of funds of a specified token which would need to be deposited
        /// to bring the position to the provided target health.
        ///
        /// This function will return 0.0 if the position is already at or over that health value.
        access(all) fun fundsRequiredForTargetHealth(pid: UInt64, type: Type, targetHealth: UFix128): UFix64 {
            return self.fundsRequiredForTargetHealthAfterWithdrawing(
                pid: pid,
                depositType: type,
                targetHealth: targetHealth,
                withdrawType: self.defaultToken,
                withdrawAmount: 0.0
            )
        }

        /// Returns the details of a given position as a PositionDetails external struct
        access(all) fun getPositionDetails(pid: UInt64): PositionDetails {
            if self.debugLogging {
                log("    [CONTRACT] getPositionDetails(pid: \(pid))")
            }
            let position = self._borrowPosition(pid: pid)
            let balances: [PositionBalance] = []

            for type in position.balances.keys {
                let balance = position.balances[type]!
                let tokenState = self._borrowUpdatedTokenState(type: type)
                let trueBalance = FlowCreditMarket.scaledBalanceToTrueBalance(
                    balance.scaledBalance,
                    interestIndex: balance.direction == BalanceDirection.Credit
                        ? tokenState.creditInterestIndex
                        : tokenState.debitInterestIndex
                )

                balances.append(PositionBalance(
                    vaultType: type,
                    direction: balance.direction,
                    balance: FlowCreditMarketMath.toUFix64Round(trueBalance)
                ))
            }

            let health = self.positionHealth(pid: pid)
            let defaultTokenAvailable = self.availableBalance(
                pid: pid,
                type: self.defaultToken,
                pullFromTopUpSource: false
            )

            return PositionDetails(
                balances: balances,
                poolDefaultToken: self.defaultToken,
                defaultTokenAvailableBalance: defaultTokenAvailable,
                health: health
            )
        }

        /// Any external party can perform a manual liquidation on a position under the following circumstances:
        /// - the position has health < 1
        /// - the liquidation price offered is better than what is available on a DEX
        /// - the liquidation results in a health <= liquidationTargetHF
        ///
        /// If a liquidation attempt is successful, the balance of the input `repayment` vault is deposited to the pool
        /// and a vault containing a balance of `seizeAmount` collateral tokens are returned to the caller.
        ///
        /// Terminology:
        /// - N means number of some token: Nc means number of collateral tokens, Nd means number of debt tokens
        /// - P means price of some token: Pc means price of collateral, Pd means price of debt
        /// - C means collateral: Ce is effective collateral, Ct is true collateral, measured in $
        /// - D means debt: De is effective debt, Dt is true debt, measured in $
        /// - Fc, Fd are collateral and debt factors
        access(all) fun manualLiquidation(
            pid: UInt64,
            debtType: Type,
            seizeType: Type,
            seizeAmount: UFix64,
            repayment: @{FungibleToken.Vault}
        ): @{FungibleToken.Vault} {
            pre {
                self.isTokenSupported(tokenType: debtType): "Debt token type unsupported: \(debtType.identifier)"
                self.isTokenSupported(tokenType: seizeType): "Collateral token type unsupported: \(seizeType.identifier)"
                debtType == repayment.getType(): "Repayment vault does not match debt type: \(debtType.identifier)!=\(repayment.getType().identifier)"
                // TODO(jord): liquidation paused / post-pause warm
            }

            let positionView = self.buildPositionView(pid: pid)
            let balanceSheet = self._getUpdatedBalanceSheet(pid: pid)
            let initialHealth = balanceSheet.health
            assert(initialHealth < 1.0, message: "Cannot liquidate healthy position: \(initialHealth)>=1")

            // Ensure liquidation amounts don't exceed position amounts
            let repayAmount = repayment.balance
            let Nc = positionView.trueBalance(ofToken: seizeType) // number of collateral tokens (true balance)
            let Nd = positionView.trueBalance(ofToken: debtType)  // number of debt tokens (true balance)
            assert(UFix128(seizeAmount) <= Nc, message: "Cannot seize more collateral than is in position: collateral balance (\(Nc)) is less than seize amount (\(seizeAmount))")
            assert(UFix128(repayAmount) <= Nd, message: "Cannot repay more debt than is in position: debt balance (\(Nd)) is less than repay amount (\(repayAmount))")

            // Oracle prices
            let Pd_oracle = self.priceOracle.price(ofToken: debtType)!  // debt price given by oracle ($/D)
            let Pc_oracle = self.priceOracle.price(ofToken: seizeType)! // collateral price given by oracle ($/C)
            // Price of collateral, denominated in debt token, implied by oracle (D/C)
            // Oracle says: "1 unit of collateral is worth `Pcd_oracle` units of debt"
            let Pcd_oracle = Pc_oracle / Pd_oracle 

            // Compute the health factor which would result if we were to accept this liquidation
            let Ce_pre = balanceSheet.effectiveCollateral // effective collateral pre-liquidation
            let De_pre = balanceSheet.effectiveDebt       // effective debt pre-liquidation
            let Fc = positionView.snapshots[seizeType]!.risk.collateralFactor
            let Fd = positionView.snapshots[debtType]!.risk.borrowFactor

            // Ce_seize = effective value of seized collateral ($)
            let Ce_seize = FlowCreditMarket.effectiveCollateral(credit: UFix128(seizeAmount), price: UFix128(Pc_oracle), collateralFactor: Fc)
            // De_seize = effective value of repaid debt ($)
            let De_seize = FlowCreditMarket.effectiveDebt(debit: UFix128(repayAmount), price:  UFix128(Pd_oracle), borrowFactor: Fd) 
            let Ce_post = Ce_pre - Ce_seize // position's total effective collateral after liquidation ($)
            let De_post = De_pre - De_seize // position's total effective debt after liquidation ($)
            let postHealth = FlowCreditMarket.healthComputation(effectiveCollateral: Ce_post, effectiveDebt: De_post)
            assert(postHealth <= self.liquidationTargetHF, message: "Liquidation must not exceed target health: post-liquidation health (\(postHealth)) is greater than target health (\(self.liquidationTargetHF))")

            // Compare the liquidation offer to liquidation via DEX. If the DEX would provide a better price, reject the offer.
            let swapper = self._getSwapperForLiquidation(seizeType: seizeType, debtType: debtType)
            // Get a quote: "how much collateral do I need to give you to get `repayAmount` debt tokens"
            let quote = swapper.quoteIn(forDesired: repayAmount, reverse: false)
            assert(seizeAmount < quote.inAmount, message: "Liquidation offer must be better than that offered by DEX")

            // Compare the DEX price to the oracle price and revert if they diverge beyond configured threshold.
            let Pcd_dex = quote.outAmount / quote.inAmount // price of collateral, denominated in debt token, implied by dex quote (D/C)
            // Compute the absolute value of the difference between the oracle price and dex price
            let Pcd_dex_oracle_diff: UFix64 = Pcd_dex < Pcd_oracle ? Pcd_oracle - Pcd_dex : Pcd_dex - Pcd_oracle
            // Compute the percent difference (eg. 0.05 for 5%). Always use the smaller price as the denominator.
            let Pcd_dex_oracle_diffPct: UFix64 = Pcd_dex < Pcd_oracle ? Pcd_dex_oracle_diff / Pcd_dex : Pcd_dex_oracle_diff / Pcd_oracle
            let Pcd_dex_oracle_diffBps = UInt16(Pcd_dex_oracle_diffPct * 10_000.0) // cannot overflow because Pcd_dex_oracle_diffPct<=1

            assert(Pcd_dex_oracle_diffBps <= self.dexOracleDeviationBps, message: "Too large difference between dex/oracle prices diff=\(Pcd_dex_oracle_diffBps)bps")

            // Execute the liquidation
            return <- self._doLiquidation(pid: pid, repayment: <-repayment, debtType: debtType, seizeType: seizeType, seizeAmount: seizeAmount)
        }

        /// Gets a swapper from the DEX for the given token pair.
        ///
        /// This function is used during liquidations to compare the liquidator's offer against the DEX price.
        /// It expects that a swapper has been configured for every supported collateral-to-debt token pair.
        ///
        /// Panics if:
        /// - No swapper is configured for the given token pair (seizeType -> debtType)
        ///
        /// @param seizeType: The collateral token type to swap from
        /// @param debtType: The debt token type to swap to
        /// @return The swapper for the given token pair
        access(self) fun _getSwapperForLiquidation(seizeType: Type, debtType: Type): {DeFiActions.Swapper} {
            return self.dex.getSwapper(inType: seizeType, outType: debtType)
                ?? panic("No DEX swapper configured for liquidation pair: \(seizeType.identifier) -> \(debtType.identifier)")
        }

        /// Internal liquidation function which performs a liquidation.
        /// The balance of `repayment` is deposited to the debt token reserve, and `seizeAmount` units of collateral are returned.
        /// Callers are responsible for checking preconditions.
        access(self) fun _doLiquidation(pid: UInt64, repayment: @{FungibleToken.Vault}, debtType: Type, seizeType: Type, seizeAmount: UFix64): @{FungibleToken.Vault} {
            pre {
                // position must have debt and collateral balance 
            }

            let repayAmount = repayment.balance
            assert(repayment.getType() == debtType, message: "Vault type mismatch for repay. Repayment type is \(repayment.getType().identifier) but debt type is \(debtType.identifier)")
            let debtReserveRef = self._borrowOrCreateReserveVault(type: debtType)
            debtReserveRef.deposit(from: <-repayment)

            // Reduce borrower's debt position by repayAmount
            let position = self._borrowPosition(pid: pid)
            let debtState = self._borrowUpdatedTokenState(type: debtType)

            if position.balances[debtType] == nil {
                position.balances[debtType] = InternalBalance(direction: BalanceDirection.Debit, scaledBalance: 0.0)
            }
            position.balances[debtType]!.recordDeposit(amount: UFix128(repayAmount), tokenState: debtState)

            // Withdraw seized collateral from position and send to liquidator
            let seizeState = self._borrowUpdatedTokenState(type: seizeType)
            if position.balances[seizeType] == nil {
                position.balances[seizeType] = InternalBalance(direction: BalanceDirection.Credit, scaledBalance: 0.0)
            }
            position.balances[seizeType]!.recordWithdrawal(amount: UFix128(seizeAmount), tokenState: seizeState)
            let seizeReserveRef = (&self.reserves[seizeType] as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?)!
            let seizedCollateral <- seizeReserveRef.withdraw(amount: seizeAmount)

            let newHealth = self.positionHealth(pid: pid)
            // TODO: sanity check health here? for auto-liquidating, we may need to perform a bounded search which could result in unbounded error in the final health

            emit LiquidationExecuted(
            	pid: pid,
            	poolUUID: self.uuid,
            	debtType: debtType.identifier,
            	repayAmount: repayAmount,
            	seizeType: seizeType.identifier,
            	seizeAmount: seizeAmount,
            	newHF: newHealth
            )

            return <-seizedCollateral
        }

        /// Returns the quantity of funds of a specified token which would need to be deposited
        /// in order to bring the position to the target health
        /// assuming we also withdraw a specified amount of another token.
        ///
        /// This function will return 0.0 if the position would already be at or over the target health value
        /// after the proposed withdrawal.
        access(all) fun fundsRequiredForTargetHealthAfterWithdrawing(
            pid: UInt64,
            depositType: Type,
            targetHealth: UFix128,
            withdrawType: Type,
            withdrawAmount: UFix64
        ): UFix64 {
            if self.debugLogging {
                log("    [CONTRACT] fundsRequiredForTargetHealthAfterWithdrawing(pid: \(pid), depositType: \(depositType.contractName!), targetHealth: \(targetHealth), withdrawType: \(withdrawType.contractName!), withdrawAmount: \(withdrawAmount))")
            }

            let balanceSheet = self._getUpdatedBalanceSheet(pid: pid)
            let position = self._borrowPosition(pid: pid)

            let adjusted = self.computeAdjustedBalancesAfterWithdrawal(
                balanceSheet: balanceSheet,
                position: position,
                withdrawType: withdrawType,
                withdrawAmount: withdrawAmount
            )

            return self.computeRequiredDepositForHealth(
                position: position,
                depositType: depositType,
                withdrawType: withdrawType,
                effectiveCollateral: adjusted.effectiveCollateral,
                effectiveDebt: adjusted.effectiveDebt,
                targetHealth: targetHealth
            )
        }

        // TODO: documentation
        access(self) fun computeAdjustedBalancesAfterWithdrawal(
            balanceSheet: BalanceSheet,
            position: &InternalPosition,
            withdrawType: Type,
            withdrawAmount: UFix64
        ): BalanceSheet {
            var effectiveCollateralAfterWithdrawal = balanceSheet.effectiveCollateral
            var effectiveDebtAfterWithdrawal = balanceSheet.effectiveDebt

            if withdrawAmount == 0.0 {
                return BalanceSheet(effectiveCollateral: effectiveCollateralAfterWithdrawal, effectiveDebt: effectiveDebtAfterWithdrawal)
            }
            if self.debugLogging {
                log("    [CONTRACT] effectiveCollateralAfterWithdrawal: \(effectiveCollateralAfterWithdrawal)")
                log("    [CONTRACT] effectiveDebtAfterWithdrawal: \(effectiveDebtAfterWithdrawal)")
            }

            let withdrawAmountU = UFix128(withdrawAmount)
            let withdrawPrice2 = UFix128(self.priceOracle.price(ofToken: withdrawType)!)
            let withdrawBorrowFactor2 = UFix128(self.borrowFactor[withdrawType]!)
            let balance = position.balances[withdrawType]
            let direction = balance?.direction ?? BalanceDirection.Debit
            let scaledBalance = balance?.scaledBalance ?? 0.0

            switch direction {
                case BalanceDirection.Debit:
                    // If the position doesn't have any collateral for the withdrawn token,
                    // we can just compute how much additional effective debt the withdrawal will create.
                    effectiveDebtAfterWithdrawal = balanceSheet.effectiveDebt +
                        (withdrawAmountU * withdrawPrice2) / withdrawBorrowFactor2

                case BalanceDirection.Credit:
                    let withdrawTokenState = self._borrowUpdatedTokenState(type: withdrawType)

                    // The user has a collateral position in the given token, we need to figure out if this withdrawal
                    // will flip over into debt, or just draw down the collateral.
                    let trueCollateral = FlowCreditMarket.scaledBalanceToTrueBalance(
                        scaledBalance,
                        interestIndex: withdrawTokenState.creditInterestIndex
                    )
                    let collateralFactor = UFix128(self.collateralFactor[withdrawType]!)
                    if trueCollateral >= withdrawAmountU {
                        // This withdrawal will draw down collateral, but won't create debt, we just need to account
                        // for the collateral decrease.
                        effectiveCollateralAfterWithdrawal = balanceSheet.effectiveCollateral -
                            (withdrawAmountU * withdrawPrice2) * collateralFactor
                    } else {
                        // The withdrawal will wipe out all of the collateral, and create some debt.
                        effectiveDebtAfterWithdrawal = balanceSheet.effectiveDebt +
                            ((withdrawAmountU - trueCollateral) * withdrawPrice2) / withdrawBorrowFactor2
                        effectiveCollateralAfterWithdrawal = balanceSheet.effectiveCollateral -
                            (trueCollateral * withdrawPrice2) * collateralFactor
                    }
            }

            return BalanceSheet(
                effectiveCollateral: effectiveCollateralAfterWithdrawal,
                effectiveDebt: effectiveDebtAfterWithdrawal
            )
        }

        // TODO(jord): ~100-line function - consider refactoring
        // TODO: documentation
         access(self) fun computeRequiredDepositForHealth(
            position: &InternalPosition,
            depositType: Type,
            withdrawType: Type,
            effectiveCollateral: UFix128,
            effectiveDebt: UFix128,
            targetHealth: UFix128
        ): UFix64 {
            let effectiveCollateralAfterWithdrawal = effectiveCollateral
            var effectiveDebtAfterWithdrawal = effectiveDebt

            if self.debugLogging {
                log("    [CONTRACT] effectiveCollateralAfterWithdrawal: \(effectiveCollateralAfterWithdrawal)")
                log("    [CONTRACT] effectiveDebtAfterWithdrawal: \(effectiveDebtAfterWithdrawal)")
            }

            // We now have new effective collateral and debt values that reflect the proposed withdrawal (if any!)
            // Now we can figure out how many of the given token would need to be deposited to bring the position
            // to the target health value.
            var healthAfterWithdrawal = FlowCreditMarket.healthComputation(
                effectiveCollateral: effectiveCollateralAfterWithdrawal,
                effectiveDebt: effectiveDebtAfterWithdrawal
            )
            if self.debugLogging {
                log("    [CONTRACT] healthAfterWithdrawal: \(healthAfterWithdrawal)")
            }

            if healthAfterWithdrawal >= targetHealth {
                // The position is already at or above the target health, so we don't need to deposit anything.
                return 0.0
            }

            // For situations where the required deposit will BOTH pay off debt and accumulate collateral, we keep
            // track of the number of tokens that went towards paying off debt.
            var debtTokenCount: UFix128 = 0.0
            let depositPrice = UFix128(self.priceOracle.price(ofToken: depositType)!)
            let depositBorrowFactor = UFix128(self.borrowFactor[depositType]!)
            let withdrawBorrowFactor = UFix128(self.borrowFactor[withdrawType]!)
            let maybeBalance = position.balances[depositType]
            if maybeBalance?.direction == BalanceDirection.Debit {
                // The user has a debt position in the given token, we start by looking at the health impact of paying off
                // the entire debt.
                let depositTokenState = self._borrowUpdatedTokenState(type: depositType)
                let debtBalance = maybeBalance!.scaledBalance
                let trueDebtTokenCount = FlowCreditMarket.scaledBalanceToTrueBalance(
                    debtBalance,
                    interestIndex: depositTokenState.debitInterestIndex
                )
                let debtEffectiveValue = (depositPrice * trueDebtTokenCount) / depositBorrowFactor

                // Ensure we don't underflow - if debtEffectiveValue is greater than effectiveDebtAfterWithdrawal,
                // it means we can pay off all debt
                var effectiveDebtAfterPayment: UFix128 = 0.0
                if debtEffectiveValue <= effectiveDebtAfterWithdrawal {
                    effectiveDebtAfterPayment = effectiveDebtAfterWithdrawal - debtEffectiveValue
                }

                // Check what the new health would be if we paid off all of this debt
                let potentialHealth = FlowCreditMarket.healthComputation(
                    effectiveCollateral: effectiveCollateralAfterWithdrawal,
                    effectiveDebt: effectiveDebtAfterPayment
                )

                // Does paying off all of the debt reach the target health? Then we're done.
                if potentialHealth >= targetHealth {
                    // We can reach the target health by paying off some or all of the debt. We can easily
                    // compute how many units of the token would be needed to reach the target health.
                    let healthChange = targetHealth - healthAfterWithdrawal
                    let requiredEffectiveDebt = effectiveDebtAfterWithdrawal
                        - (effectiveCollateralAfterWithdrawal / targetHealth)

                    // The amount of the token to pay back, in units of the token.
                    let paybackAmount = (requiredEffectiveDebt * depositBorrowFactor) / depositPrice

                    if self.debugLogging {
                        log("    [CONTRACT] paybackAmount: \(paybackAmount)")
                    }

                    return FlowCreditMarketMath.toUFix64RoundUp(paybackAmount)
                } else {
                    // We can pay off the entire debt, but we still need to deposit more to reach the target health.
                    // We have logic below that can determine the collateral deposition required to reach the target health
                    // from this new health position. Rather than copy that logic here, we fall through into it. But first
                    // we have to record the amount of tokens that went towards debt payback and adjust the effective
                    // debt to reflect that it has been paid off.
                    debtTokenCount = trueDebtTokenCount
                    // Ensure we don't underflow
                    if debtEffectiveValue <= effectiveDebtAfterWithdrawal {
                        effectiveDebtAfterWithdrawal = effectiveDebtAfterWithdrawal - debtEffectiveValue
                    } else {
                        effectiveDebtAfterWithdrawal = 0.0
                    }
                    healthAfterWithdrawal = potentialHealth
                }
            }

            // At this point, we're either dealing with a position that didn't have a debt position in the deposit
            // token, or we've accounted for the debt payoff and adjusted the effective debt above.
            // Now we need to figure out how many tokens would need to be deposited (as collateral) to reach the
            // target health. We can rearrange the health equation to solve for the required collateral:

            // We need to increase the effective collateral from its current value to the required value, so we
            // multiply the required health change by the effective debt, and turn that into a token amount.
            let healthChangeU = targetHealth - healthAfterWithdrawal
            // TODO: apply the same logic as below to the early return blocks above
            let depositCollateralFactor = UFix128(self.collateralFactor[depositType]!)
            let requiredEffectiveCollateral = (healthChangeU * effectiveDebtAfterWithdrawal) / depositCollateralFactor

            // The amount of the token to deposit, in units of the token.
            let collateralTokenCount = requiredEffectiveCollateral / depositPrice
            if self.debugLogging {
                log("    [CONTRACT] requiredEffectiveCollateral: \(requiredEffectiveCollateral)")
                log("    [CONTRACT] collateralTokenCount: \(collateralTokenCount)")
                log("    [CONTRACT] debtTokenCount: \(debtTokenCount)")
                log("    [CONTRACT] collateralTokenCount + debtTokenCount: \(collateralTokenCount) + \(debtTokenCount) = \(collateralTokenCount + debtTokenCount)")
            }

            // debtTokenCount is the number of tokens that went towards debt, zero if there was no debt.
            return FlowCreditMarketMath.toUFix64Round(collateralTokenCount + debtTokenCount)
        }

        /// Returns the quantity of the specified token that could be withdrawn
        /// while still keeping the position's health at or above the provided target.
        access(all) fun fundsAvailableAboveTargetHealth(pid: UInt64, type: Type, targetHealth: UFix128): UFix64 {
            return self.fundsAvailableAboveTargetHealthAfterDepositing(
                pid: pid,
                withdrawType: type,
                targetHealth: targetHealth,
                depositType: self.defaultToken,
                depositAmount: 0.0
            )
        }

        /// Returns the quantity of the specified token that could be withdrawn
        /// while still keeping the position's health at or above the provided target,
        /// assuming we also deposit a specified amount of another token.
        access(all) fun fundsAvailableAboveTargetHealthAfterDepositing(
            pid: UInt64,
            withdrawType: Type,
            targetHealth: UFix128,
            depositType: Type,
            depositAmount: UFix64
        ): UFix64 {
            if self.debugLogging {
                log("    [CONTRACT] fundsAvailableAboveTargetHealthAfterDepositing(pid: \(pid), withdrawType: \(withdrawType.contractName!), targetHealth: \(targetHealth), depositType: \(depositType.contractName!), depositAmount: \(depositAmount))")
            }
            if depositType == withdrawType && depositAmount > 0.0 {
                // If the deposit and withdrawal types are the same, we compute the available funds assuming
                // no deposit (which is less work) and increase that by the deposit amount at the end
                let fundsAvailable = self.fundsAvailableAboveTargetHealth(
                    pid: pid,
                    type: withdrawType,
                    targetHealth: targetHealth
                )
                return fundsAvailable + depositAmount
            }

            let balanceSheet = self._getUpdatedBalanceSheet(pid: pid)
            let position = self._borrowPosition(pid: pid)

            let adjusted = self.computeAdjustedBalancesAfterDeposit(
                balanceSheet: balanceSheet,
                position: position,
                depositType: depositType,
                depositAmount: depositAmount
            )

            return self.computeAvailableWithdrawal(
                position: position,
                withdrawType: withdrawType,
                effectiveCollateral: adjusted.effectiveCollateral,
                effectiveDebt: adjusted.effectiveDebt,
                targetHealth: targetHealth
            )
        }

        // Helper function to compute balances after deposit
        access(self) fun computeAdjustedBalancesAfterDeposit(
            balanceSheet: BalanceSheet,
            position: &InternalPosition,
            depositType: Type,
            depositAmount: UFix64
        ): BalanceSheet {
            var effectiveCollateralAfterDeposit = balanceSheet.effectiveCollateral
            var effectiveDebtAfterDeposit = balanceSheet.effectiveDebt

            if self.debugLogging {
                log("    [CONTRACT] effectiveCollateralAfterDeposit: \(effectiveCollateralAfterDeposit)")
                log("    [CONTRACT] effectiveDebtAfterDeposit: \(effectiveDebtAfterDeposit)")
            }
            if depositAmount == 0.0 {
                return BalanceSheet(
                    effectiveCollateral: effectiveCollateralAfterDeposit,
                    effectiveDebt: effectiveDebtAfterDeposit
                )
            }

            let depositAmountCasted = UFix128(depositAmount)
            let depositPriceCasted = UFix128(self.priceOracle.price(ofToken: depositType)!)
            let depositBorrowFactorCasted = UFix128(self.borrowFactor[depositType]!)
            let depositCollateralFactorCasted = UFix128(self.collateralFactor[depositType]!)
            let balance = position.balances[depositType]
            let direction = balance?.direction ?? BalanceDirection.Credit
            let scaledBalance = balance?.scaledBalance ?? 0.0

            switch direction {
                case BalanceDirection.Credit:
                    // If there's no debt for the deposit token,
                    // we can just compute how much additional effective collateral the deposit will create.
                    effectiveCollateralAfterDeposit = balanceSheet.effectiveCollateral +
                        (depositAmountCasted * depositPriceCasted) * depositCollateralFactorCasted

                case BalanceDirection.Debit:
                    let depositTokenState = self._borrowUpdatedTokenState(type: depositType)

                    // The user has a debt position in the given token, we need to figure out if this deposit
                    // will result in net collateral, or just bring down the debt.
                    let trueDebt = FlowCreditMarket.scaledBalanceToTrueBalance(
                        scaledBalance,
                        interestIndex: depositTokenState.debitInterestIndex
                    )
                    if self.debugLogging {
                        log("    [CONTRACT] trueDebt: \(trueDebt)")
                    }

                    if trueDebt >= depositAmountCasted {
                        // This deposit will pay down some debt, but won't result in net collateral, we
                        // just need to account for the debt decrease.
                        // TODO - validate if this should deal with withdrawType or depositType
                        effectiveDebtAfterDeposit = balanceSheet.effectiveDebt -
                            (depositAmountCasted * depositPriceCasted) / depositBorrowFactorCasted
                    } else {
                        // The deposit will wipe out all of the debt, and create some collateral.
                        // TODO - validate if this should deal with withdrawType or depositType
                        effectiveDebtAfterDeposit = balanceSheet.effectiveDebt -
                            (trueDebt * depositPriceCasted) / depositBorrowFactorCasted
                        effectiveCollateralAfterDeposit = balanceSheet.effectiveCollateral +
                            (depositAmountCasted - trueDebt) * depositPriceCasted * depositCollateralFactorCasted
                    }
            }

            if self.debugLogging {
                log("    [CONTRACT] effectiveCollateralAfterDeposit: \(effectiveCollateralAfterDeposit)")
                log("    [CONTRACT] effectiveDebtAfterDeposit: \(effectiveDebtAfterDeposit)")
            }

            // We now have new effective collateral and debt values that reflect the proposed deposit (if any!).
            // Now we can figure out how many of the withdrawal token are available while keeping the position
            // at or above the target health value.
            return BalanceSheet(
                effectiveCollateral: effectiveCollateralAfterDeposit,
                effectiveDebt: effectiveDebtAfterDeposit
            )
        }

        // Helper function to compute available withdrawal
        // TODO(jord): ~100-line function - consider refactoring
        access(self) fun computeAvailableWithdrawal(
            position: &InternalPosition,
            withdrawType: Type,
            effectiveCollateral: UFix128,
            effectiveDebt: UFix128,
            targetHealth: UFix128
        ): UFix64 {
            var effectiveCollateralAfterDeposit = effectiveCollateral
            let effectiveDebtAfterDeposit = effectiveDebt

            let healthAfterDeposit = FlowCreditMarket.healthComputation(
                effectiveCollateral: effectiveCollateralAfterDeposit,
                effectiveDebt: effectiveDebtAfterDeposit
            )
            if self.debugLogging {
                log("    [CONTRACT] healthAfterDeposit: \(healthAfterDeposit)")
            }

            if healthAfterDeposit <= targetHealth {
                // The position is already at or below the provided target health, so we can't withdraw anything.
                return 0.0
            }

            // For situations where the available withdrawal will BOTH draw down collateral and create debt, we keep
            // track of the number of tokens that are available from collateral
            var collateralTokenCount: UFix128 = 0.0

            let withdrawPrice = UFix128(self.priceOracle.price(ofToken: withdrawType)!)
            let withdrawCollateralFactor = UFix128(self.collateralFactor[withdrawType]!)
            let withdrawBorrowFactor = UFix128(self.borrowFactor[withdrawType]!)

            let maybeBalance = position.balances[withdrawType]
            if maybeBalance?.direction == BalanceDirection.Credit {
                // The user has a credit position in the withdraw token, we start by looking at the health impact of pulling out all
                // of that collateral
                let withdrawTokenState = self._borrowUpdatedTokenState(type: withdrawType)
                let creditBalance = maybeBalance!.scaledBalance
                let trueCredit = FlowCreditMarket.scaledBalanceToTrueBalance(
                    creditBalance,
                    interestIndex: withdrawTokenState.creditInterestIndex
                )
                let collateralEffectiveValue = (withdrawPrice * trueCredit) * withdrawCollateralFactor

                // Check what the new health would be if we took out all of this collateral
                let potentialHealth = FlowCreditMarket.healthComputation(
                    effectiveCollateral: effectiveCollateralAfterDeposit - collateralEffectiveValue, // ??? - why subtract?
                    effectiveDebt: effectiveDebtAfterDeposit
                )

                // Does drawing down all of the collateral go below the target health? Then the max withdrawal comes from collateral only.
                if potentialHealth <= targetHealth {
                    // We will hit the health target before using up all of the withdraw token credit. We can easily
                    // compute how many units of the token would bring the position down to the target health.
                    // We will hit the health target before using up all available withdraw credit.

                    let availableEffectiveValue = effectiveCollateralAfterDeposit - (targetHealth * effectiveDebtAfterDeposit)
                    if self.debugLogging {
                        log("    [CONTRACT] availableEffectiveValue: \(availableEffectiveValue)")
                    }

                    // The amount of the token we can take using that amount of health
                    let availableTokenCount = (availableEffectiveValue / withdrawCollateralFactor) / withdrawPrice
                    if self.debugLogging {
                        log("    [CONTRACT] availableTokenCount: \(availableTokenCount)")
                    }

                    return FlowCreditMarketMath.toUFix64RoundDown(availableTokenCount)
                } else {
                    // We can flip this credit position into a debit position, before hitting the target health.
                    // We have logic below that can determine health changes for debit positions. We've copied it here
                    // with an added handling for the case where the health after deposit is an edgecase
                    collateralTokenCount = trueCredit
                    effectiveCollateralAfterDeposit = effectiveCollateralAfterDeposit - collateralEffectiveValue
                    if self.debugLogging {
                        log("    [CONTRACT] collateralTokenCount: \(collateralTokenCount)")
                        log("    [CONTRACT] effectiveCollateralAfterDeposit: \(effectiveCollateralAfterDeposit)")
                    }

                    // We can calculate the available debt increase that would bring us to the target health
                    let availableDebtIncrease = (effectiveCollateralAfterDeposit / targetHealth) - effectiveDebtAfterDeposit
                    let availableTokens = (availableDebtIncrease * withdrawBorrowFactor) / withdrawPrice
                    if self.debugLogging {
                        log("    [CONTRACT] availableDebtIncrease: \(availableDebtIncrease)")
                        log("    [CONTRACT] availableTokens: \(availableTokens)")
                        log("    [CONTRACT] availableTokens + collateralTokenCount: \(availableTokens + collateralTokenCount)")
                    }
                    return FlowCreditMarketMath.toUFix64RoundDown(availableTokens + collateralTokenCount)
                }
            }

            // At this point, we're either dealing with a position that didn't have a credit balance in the withdraw
            // token, or we've accounted for the credit balance and adjusted the effective collateral above.

            // We can calculate the available debt increase that would bring us to the target health
            let availableDebtIncrease = (effectiveCollateralAfterDeposit / targetHealth) - effectiveDebtAfterDeposit
            let availableTokens = (availableDebtIncrease * withdrawBorrowFactor) / withdrawPrice
            if self.debugLogging {
                log("    [CONTRACT] availableDebtIncrease: \(availableDebtIncrease)")
                log("    [CONTRACT] availableTokens: \(availableTokens)")
                log("    [CONTRACT] availableTokens + collateralTokenCount: \(availableTokens + collateralTokenCount)")
            }
            return FlowCreditMarketMath.toUFix64RoundDown(availableTokens + collateralTokenCount)
        }

        /// Returns the position's health if the given amount of the specified token were deposited
        access(all) fun healthAfterDeposit(pid: UInt64, type: Type, amount: UFix64): UFix128 {
            let balanceSheet = self._getUpdatedBalanceSheet(pid: pid)
            let position = self._borrowPosition(pid: pid)
            let tokenState = self._borrowUpdatedTokenState(type: type)

            var effectiveCollateralIncrease: UFix128 = 0.0
            var effectiveDebtDecrease: UFix128 = 0.0

            let amountU = UFix128(amount)
            let price = UFix128(self.priceOracle.price(ofToken: type)!)
            let collateralFactor = UFix128(self.collateralFactor[type]!)
            let borrowFactor = UFix128(self.borrowFactor[type]!)
            let balance = position.balances[type]
            let direction = balance?.direction ?? BalanceDirection.Credit
            let scaledBalance = balance?.scaledBalance ?? 0.0
            switch direction {
                case BalanceDirection.Credit:
                    // Since the user has no debt in the given token,
                    // we can just compute how much additional collateral this deposit will create.
                    effectiveCollateralIncrease = (amountU * price) * collateralFactor

                case BalanceDirection.Debit:
                    // The user has a debit position in the given token,
                    // we need to figure out if this deposit will only pay off some of the debt,
                    // or if it will also create new collateral.
                    let trueDebt = FlowCreditMarket.scaledBalanceToTrueBalance(
                        scaledBalance,
                        interestIndex: tokenState.debitInterestIndex
                    )

                    if trueDebt >= amountU {
                        // This deposit will wipe out some or all of the debt, but won't create new collateral,
                        // we just need to account for the debt decrease.
                        effectiveDebtDecrease = (amountU * price) / borrowFactor
                    } else {
                        // This deposit will wipe out all of the debt, and create new collateral.
                        effectiveDebtDecrease = (trueDebt * price) / borrowFactor
                        effectiveCollateralIncrease = (amountU - trueDebt) * price * collateralFactor
                    }
            }

            return FlowCreditMarket.healthComputation(
                effectiveCollateral: balanceSheet.effectiveCollateral + effectiveCollateralIncrease,
                effectiveDebt: balanceSheet.effectiveDebt - effectiveDebtDecrease
            )
        }

        // Returns health value of this position if the given amount of the specified token were withdrawn without
        // using the top up source.
        // NOTE: This method can return health values below 1.0, which aren't actually allowed. This indicates
        // that the proposed withdrawal would fail (unless a top up source is available and used).
        access(all) fun healthAfterWithdrawal(pid: UInt64, type: Type, amount: UFix64): UFix128 {
            let balanceSheet = self._getUpdatedBalanceSheet(pid: pid)
            let position = self._borrowPosition(pid: pid)
            let tokenState = self._borrowUpdatedTokenState(type: type)

            var effectiveCollateralDecrease: UFix128 = 0.0
            var effectiveDebtIncrease: UFix128 = 0.0

            let amountU = UFix128(amount)
            let price = UFix128(self.priceOracle.price(ofToken: type)!)
            let collateralFactor = UFix128(self.collateralFactor[type]!)
            let borrowFactor = UFix128(self.borrowFactor[type]!)
            let balance = position.balances[type]
            let direction = balance?.direction ?? BalanceDirection.Debit
            let scaledBalance = balance?.scaledBalance ?? 0.0

            switch direction {
                case BalanceDirection.Debit:
                    // The user has no credit position in the given token,
                    // we can just compute how much additional effective debt this withdrawal will create.
                    effectiveDebtIncrease = (amountU * price) / borrowFactor

                case BalanceDirection.Credit:
                    // The user has a credit position in the given token,
                    // we need to figure out if this withdrawal will only draw down some of the collateral,
                    // or if it will also create new debt.
                    let trueCredit = FlowCreditMarket.scaledBalanceToTrueBalance(
                        scaledBalance,
                        interestIndex: tokenState.creditInterestIndex
                    )

                    if trueCredit >= amountU {
                        // This withdrawal will draw down some collateral, but won't create new debt,
                        // we just need to account for the collateral decrease.
                        effectiveCollateralDecrease = (amountU * price) * collateralFactor
                    } else {
                        // The withdrawal will wipe out all of the collateral, and create new debt.
                        effectiveDebtIncrease = ((amountU - trueCredit) * price) / borrowFactor
                        effectiveCollateralDecrease = (trueCredit * price) * collateralFactor
                    }
            }

            return FlowCreditMarket.healthComputation(
                effectiveCollateral: balanceSheet.effectiveCollateral - effectiveCollateralDecrease,
                effectiveDebt: balanceSheet.effectiveDebt + effectiveDebtIncrease
            )
        }

        ///////////////////////////
        // POSITION MANAGEMENT
        ///////////////////////////

        /// Creates a lending position against the provided collateral funds,
        /// depositing the loaned amount to the given Sink.
        /// If a Source is provided, the position will be configured to pull loan repayment
        /// when the loan becomes undercollateralized, preferring repayment to outright liquidation.
        /// TODO(jord): it does not seem like there is any permission system for positions. Anyone with (auth EPosition) &Pool can operate on any position.
        access(EParticipant) fun createPosition(
            funds: @{FungibleToken.Vault},
            issuanceSink: {DeFiActions.Sink},
            repaymentSource: {DeFiActions.Source}?,
            pushToDrawDownSink: Bool
        ): UInt64 {
            pre {
                self.globalLedger[funds.getType()] != nil:
                    "Invalid token type \(funds.getType().identifier) - not supported by this Pool"
                // TODO(jord): Sink/source should be valid
            }
            // construct a new InternalPosition, assigning it the current position ID
            let id = self.nextPositionID
            self.nextPositionID = self.nextPositionID + 1
            self.positions[id] <-! create InternalPosition()

            emit Opened(
                pid: id,
                poolUUID: self.uuid
            )

            // assign issuance & repayment connectors within the InternalPosition
            let iPos = self._borrowPosition(pid: id)
            let fundsType = funds.getType()
            iPos.setDrawDownSink(issuanceSink)
            if repaymentSource != nil {
                iPos.setTopUpSource(repaymentSource)
            }

            // deposit the initial funds & return the position ID
            self.depositAndPush(
                pid: id,
                from: <-funds,
                pushToDrawDownSink: pushToDrawDownSink
            )
            return id
        }

        /// Allows anyone to deposit funds into any position.
        /// If the provided Vault is not supported by the Pool, the operation reverts.
        access(EParticipant) fun depositToPosition(pid: UInt64, from: @{FungibleToken.Vault}) {
            self.depositAndPush(
                pid: pid,
                from: <-from,
                pushToDrawDownSink: false
            )
        }

        /// Deposits the provided funds to the specified position with the configurable `pushToDrawDownSink` option.
        /// If `pushToDrawDownSink` is true, excess value putting the position above its max health
        /// is pushed to the position's configured `drawDownSink`.
        /// TODO(jord): ~100-line function - consider refactoring.
        access(EPosition) fun depositAndPush(
            pid: UInt64,
            from: @{FungibleToken.Vault},
            pushToDrawDownSink: Bool
        ) {
            pre {
                self.positions[pid] != nil:
                    "Invalid position ID \(pid) - could not find an InternalPosition with the requested ID in the Pool"
                self.globalLedger[from.getType()] != nil:
                    "Invalid token type \(from.getType().identifier) - not supported by this Pool"
            }
            if self.debugLogging {
                log("    [CONTRACT] depositAndPush(pid: \(pid), pushToDrawDownSink: \(pushToDrawDownSink))")
            }

            if from.balance == 0.0 {
                Burner.burn(<-from)
                return
            }

            // Get a reference to the user's position and global token state for the affected token.
            let type = from.getType()
            let position = self._borrowPosition(pid: pid)
            let tokenState = self._borrowUpdatedTokenState(type: type)
            let amount = from.balance
            let depositedUUID = from.uuid

            // Time-based state is handled by the tokenState() helper function

            // Deposit rate limiting: prevent a single large deposit from monopolizing capacity.
            // Excess is queued to be processed asynchronously (see asyncUpdatePosition).
            let depositAmount = from.balance
            let depositLimit = tokenState.depositLimit()

            if depositAmount > depositLimit {
                // The deposit is too big, so we need to queue the excess
                let queuedDeposit <- from.withdraw(amount: depositAmount - depositLimit)

                if position.queuedDeposits[type] == nil {
                    position.queuedDeposits[type] <-! queuedDeposit
                } else {
                    position.queuedDeposits[type]!.deposit(from: <-queuedDeposit)
                }
            }

            // Per-user deposit limit: check if user has exceeded their per-user limit
            let userDepositLimitCap = tokenState.getUserDepositLimitCap()
            let currentUsage = tokenState.depositUsage[pid] ?? 0.0
            let remainingUserLimit = userDepositLimitCap - currentUsage
            
            // If the deposit would exceed the user's limit, queue or reject the excess
            if from.balance > remainingUserLimit {
                let excessAmount = from.balance - remainingUserLimit
                let queuedForUserLimit <- from.withdraw(amount: excessAmount)
                
                if position.queuedDeposits[type] == nil {
                    position.queuedDeposits[type] <-! queuedForUserLimit
                } else {
                    position.queuedDeposits[type]!.deposit(from: <-queuedForUserLimit)
                }
            }

            // If this position doesn't currently have an entry for this token, create one.
            if position.balances[type] == nil {
                position.balances[type] = InternalBalance(
                    direction: BalanceDirection.Credit,
                    scaledBalance: 0.0
                )
            }

            // Create vault if it doesn't exist yet
            if self.reserves[type] == nil {
                self.reserves[type] <-! from.createEmptyVault()
            }
            let reserveVault = (&self.reserves[type] as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?)!

            // Reflect the deposit in the position's balance.
            //
            // This only records the portion of the deposit that was accepted, not any queued portions,
            // as the queued deposits will be processed later (by this function being called again), and therefore
            // will be recorded at that time.
            let acceptedAmount = from.balance
            position.balances[type]!.recordDeposit(
                amount: UFix128(acceptedAmount),
                tokenState: tokenState
            )

            // Consume deposit capacity for the accepted deposit amount and track per-user usage
            // Only the accepted amount consumes capacity; queued portions will consume capacity when processed later
            tokenState.consumeDepositCapacity(acceptedAmount, pid: pid)

            // Add the money to the reserves
            reserveVault.deposit(from: <-from)

            // Rebalancing and queue management
            if pushToDrawDownSink {
                self.rebalancePosition(pid: pid, force: true)
            }

            self._queuePositionForUpdateIfNecessary(pid: pid)
            emit Deposited(
                pid: pid,
                poolUUID: self.uuid,
                vaultType: type,
                amount: amount,
                depositedUUID: depositedUUID
            )
        }

        /// Withdraws the requested funds from the specified position.
        ///
        /// Callers should be careful that the withdrawal does not put their position under its target health,
        /// especially if the position doesn't have a configured `topUpSource` from which to repay borrowed funds
        // in the event of undercollaterlization.
        access(EPosition) fun withdraw(pid: UInt64, amount: UFix64, type: Type): @{FungibleToken.Vault} {
            // Call the enhanced function with pullFromTopUpSource = false for backward compatibility
            return <- self.withdrawAndPull(
                pid: pid,
                type: type,
                amount: amount,
                pullFromTopUpSource: false
            )
        }

        /// Withdraws the requested funds from the specified position
        /// with the configurable `pullFromTopUpSource` option.
        ///
        /// If `pullFromTopUpSource` is true, deficient value putting the position below its min health
        /// is pulled from the position's configured `topUpSource`.
        /// TODO(jord): ~150-line function - consider refactoring.
        access(EPosition) fun withdrawAndPull(
            pid: UInt64,
            type: Type,
            amount: UFix64,
            pullFromTopUpSource: Bool
        ): @{FungibleToken.Vault} {
            pre {
                self.positions[pid] != nil:
                    "Invalid position ID \(pid) - could not find an InternalPosition with the requested ID in the Pool"
                self.globalLedger[type] != nil:
                    "Invalid token type \(type.identifier) - not supported by this Pool"
            }
            if self.debugLogging {
                log("    [CONTRACT] withdrawAndPull(pid: \(pid), type: \(type.identifier), amount: \(amount), pullFromTopUpSource: \(pullFromTopUpSource))")
            }
            if amount == 0.0 {
                return <- DeFiActionsUtils.getEmptyVault(type)
            }

            // Get a reference to the user's position and global token state for the affected token.
            let position = self._borrowPosition(pid: pid)
            let tokenState = self._borrowUpdatedTokenState(type: type)

            // Global interest indices are updated via tokenState() helper

            // Preflight to see if the funds are available
            let topUpSource = position.topUpSource as auth(FungibleToken.Withdraw) &{DeFiActions.Source}?
            let topUpType = topUpSource?.getSourceType() ?? self.defaultToken

            let requiredDeposit = self.fundsRequiredForTargetHealthAfterWithdrawing(
                pid: pid,
                depositType: topUpType,
                targetHealth: position.minHealth,
                withdrawType: type,
                withdrawAmount: amount
            )

            var canWithdraw = false
            var usedTopUp = false

            if requiredDeposit == 0.0 {
                // We can service this withdrawal without any top up
                canWithdraw = true
            } else if pullFromTopUpSource {
                // We need more funds to service this withdrawal, see if they are available from the top up source
                if let topUpSource = topUpSource {
                    // If we have to rebalance, let's try to rebalance to the target health, not just the minimum
                    let idealDeposit = self.fundsRequiredForTargetHealthAfterWithdrawing(
                        pid: pid,
                        depositType: topUpType,
                        targetHealth: position.targetHealth,
                        withdrawType: type,
                        withdrawAmount: amount
                    )

                    let pulledVault <- topUpSource.withdrawAvailable(maxAmount: idealDeposit)
                    let pulledAmount = pulledVault.balance

                    // NOTE: We requested the "ideal" deposit, but we compare against the required deposit here.
                    // The top up source may not have enough funds get us to the target health, but could have
                    // enough to keep us over the minimum.
                    if pulledAmount >= requiredDeposit {
                        // We can service this withdrawal if we deposit funds from our top up source
                        self.depositAndPush(
                            pid: pid,
                            from: <-pulledVault,
                            pushToDrawDownSink: false
                        )
                        usedTopUp = pulledAmount > 0.0
                        canWithdraw = true
                    } else {
                        // We can't get the funds required to service this withdrawal, so we need to redeposit what we got
                        self.depositAndPush(
                            pid: pid,
                            from: <-pulledVault,
                            pushToDrawDownSink: false
                        )
                        usedTopUp = pulledAmount > 0.0
                    }
                }
            }

            if !canWithdraw {
                // Log detailed information about the failed withdrawal (only if debugging enabled)
                if self.debugLogging {
                    let availableBalance = self.availableBalance(pid: pid, type: type, pullFromTopUpSource: false)
                    log("    [CONTRACT] WITHDRAWAL FAILED:")
                    log("    [CONTRACT] Position ID: \(pid)")
                    log("    [CONTRACT] Token type: \(type.identifier)")
                    log("    [CONTRACT] Requested amount: \(amount)")
                    log("    [CONTRACT] Available balance (without topUp): \(availableBalance)")
                    log("    [CONTRACT] Required deposit for minHealth: \(requiredDeposit)")
                    log("    [CONTRACT] Pull from topUpSource: \(pullFromTopUpSource)")
                }

                // We can't service this withdrawal, so we just abort
                panic("Cannot withdraw \(amount) of \(type.identifier) from position ID \(pid) - Insufficient funds for withdrawal")
            }

            // If this position doesn't currently have an entry for this token, create one.
            if position.balances[type] == nil {
                position.balances[type] = InternalBalance(
                    direction: BalanceDirection.Credit,
                    scaledBalance: 0.0
                )
            }

            let reserveVault = (&self.reserves[type] as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?)!

            // Reflect the withdrawal in the position's balance
            let uintAmount = UFix128(amount)
            position.balances[type]!.recordWithdrawal(
                amount: uintAmount,
                tokenState: tokenState
            )
            // Ensure that this withdrawal doesn't cause the position to be overdrawn.
            // Skip the assertion only when a top-up was used in this call and the immediate
            // post-withdrawal health is 0 (transitional state before top-up effects fully reflect).
            let postHealth = self.positionHealth(pid: pid)
            if !(usedTopUp && postHealth == 0.0) {
                assert(
                    position.minHealth <= postHealth,
                    message: "Position is overdrawn"
                )
            }

            // Queue for update if necessary
            self._queuePositionForUpdateIfNecessary(pid: pid)

            let withdrawn <- reserveVault.withdraw(amount: amount)

            emit Withdrawn(
                pid: pid,
                poolUUID: self.uuid,
                vaultType: type,
                amount: withdrawn.balance,
                withdrawnUUID: withdrawn.uuid
            )

            return <- withdrawn
        }

        /// Sets the InternalPosition's drawDownSink. If `nil`, the Pool will not be able to push overflown value when
        /// the position exceeds its maximum health. Note, if a non-nil value is provided, the Sink MUST accept the
        /// Pool's default deposits or the operation will revert.
        access(EPosition) fun provideDrawDownSink(pid: UInt64, sink: {DeFiActions.Sink}?) {
            let position = self._borrowPosition(pid: pid)
            position.setDrawDownSink(sink)
        }

        /// Sets the InternalPosition's topUpSource.
        /// If `nil`, the Pool will not be able to pull underflown value when
        /// the position falls below its minimum health which may result in liquidation.
        access(EPosition) fun provideTopUpSource(pid: UInt64, source: {DeFiActions.Source}?) {
            let position = self._borrowPosition(pid: pid)
            position.setTopUpSource(source)
        }

        // ---- Position health accessors (called via Position using EPosition capability) ----

        access(EPosition) view fun readTargetHealth(pid: UInt64): UFix128 {
            let pos = self._borrowPosition(pid: pid)
            return pos.targetHealth
        }

        access(EPosition) view fun readMinHealth(pid: UInt64): UFix128 {
            let pos = self._borrowPosition(pid: pid)
            return pos.minHealth
        }

        access(EPosition) view fun readMaxHealth(pid: UInt64): UFix128 {
            let pos = self._borrowPosition(pid: pid)
            return pos.maxHealth
        }

        access(EPosition) fun writeTargetHealth(pid: UInt64, targetHealth: UFix128) {
            let pos = self._borrowPosition(pid: pid)
            assert(
                targetHealth >= pos.minHealth,
                message: "targetHealth must be ≥ minHealth"
            )
            assert(
                targetHealth <= pos.maxHealth,
                message: "targetHealth must be ≤ maxHealth"
            )
            pos.setTargetHealth(targetHealth)
        }

        access(EPosition) fun writeMinHealth(pid: UInt64, minHealth: UFix128) {
            let pos = self._borrowPosition(pid: pid)
            assert(
                minHealth <= pos.targetHealth,
                message: "minHealth must be ≤ targetHealth"
            )
            pos.setMinHealth(minHealth)
        }

        access(EPosition) fun writeMaxHealth(pid: UInt64, maxHealth: UFix128) {
            let pos = self._borrowPosition(pid: pid)
            assert(
                maxHealth >= pos.targetHealth,
                message: "maxHealth must be ≥ targetHealth"
            )
            pos.setMaxHealth(maxHealth)
        }

        ///////////////////////
        // POOL MANAGEMENT
        ///////////////////////

        /// Updates liquidation-related parameters (any nil values are ignored)
        access(EGovernance) fun setLiquidationParams(
            targetHF: UFix128?,
            warmupSec: UInt64?,
        ) {
            var newTarget = self.liquidationTargetHF
            var newWarmup = self.liquidationWarmupSec
            if let targetHF = targetHF {
                assert(
                    targetHF > 1.0,
                    message: "targetHF must be > 1.0"
                )
                self.liquidationTargetHF = targetHF
                newTarget = targetHF
            }
            if let warmupSec = warmupSec {
                self.liquidationWarmupSec = warmupSec
                newWarmup = warmupSec
            }

            emit LiquidationParamsUpdated(
                poolUUID: self.uuid,
                targetHF: newTarget,
                warmupSec: newWarmup,
            )
        }

        /// Governance: set DEX oracle deviation guard and toggle allowlisted swapper types
        access(EGovernance) fun setDexLiquidationConfig(
            dexOracleDeviationBps: UInt16?,
            allowSwappers: [Type]?,
            disallowSwappers: [Type]?,
            dexMaxSlippageBps: UInt64?,
            dexMaxRouteHops: UInt64?
        ) {
            if let dexOracleDeviationBps = dexOracleDeviationBps {
                self.dexOracleDeviationBps = dexOracleDeviationBps
            }
            if let allowSwappers = allowSwappers {
                for t in allowSwappers {
                    self.allowedSwapperTypes[t] = true
                }
            }
            if let disallowSwappers = disallowSwappers {
                for t in disallowSwappers {
                    self.allowedSwapperTypes.remove(key: t)
                }
            }
            if let dexMaxSlippageBps = dexMaxSlippageBps {
                self.dexMaxSlippageBps = dexMaxSlippageBps
            }
            if let dexMaxRouteHops = dexMaxRouteHops {
                self.dexMaxRouteHops = dexMaxRouteHops
            }
        }

        /// Pauses or unpauses liquidations; when unpausing, starts a warm-up window
        access(EGovernance) fun pauseLiquidations(flag: Bool) {
            if flag {
                self.liquidationsPaused = true
                emit LiquidationsPaused(poolUUID: self.uuid)
            } else {
                self.liquidationsPaused = false
                let now = UInt64(getCurrentBlock().timestamp)
                self.lastUnpausedAt = now
                emit LiquidationsUnpaused(
                    poolUUID: self.uuid,
                    warmupEndsAt: now + self.liquidationWarmupSec
                )
            }
        }

        /// Adds a new token type to the pool with the given parameters defining borrowing limits on collateral,
        /// interest accumulation, deposit rate limiting, and deposit size capacity
        access(EGovernance) fun addSupportedToken(
            tokenType: Type,
            collateralFactor: UFix64,
            borrowFactor: UFix64,
            interestCurve: {InterestCurve},
            depositRate: UFix64,
            depositCapacityCap: UFix64
        ) {
            pre {
                self.globalLedger[tokenType] == nil:
                    "Token type already supported"
                tokenType.isSubtype(of: Type<@{FungibleToken.Vault}>()):
                    "Invalid token type \(tokenType.identifier) - tokenType must be a FungibleToken Vault implementation"
                collateralFactor > 0.0 && collateralFactor <= 1.0:
                    "Collateral factor must be between 0 and 1"
                borrowFactor > 0.0 && borrowFactor <= 1.0:
                    "Borrow factor must be between 0 and 1"
                depositRate > 0.0:
                    "Deposit rate must be positive"
                depositCapacityCap > 0.0:
                    "Deposit capacity cap must be positive"
                DeFiActionsUtils.definingContractIsFungibleToken(tokenType):
                    "Invalid token contract definition for tokenType \(tokenType.identifier) - defining contract is not FungibleToken conformant"
            }

            // Add token to global ledger with its interest curve and deposit parameters
            self.globalLedger[tokenType] = TokenState(
                tokenType: tokenType,
                interestCurve: interestCurve,
                depositRate: depositRate,
                depositCapacityCap: depositCapacityCap
            )

            // Set collateral factor (what percentage of value can be used as collateral)
            self.collateralFactor[tokenType] = collateralFactor

            // Set borrow factor (risk adjustment for borrowed amounts)
            self.borrowFactor[tokenType] = borrowFactor

            // Default liquidation bonus per token = 5%
            self.liquidationBonus[tokenType] = 0.05
        }

        // Removed: addSupportedTokenWithLiquidationBonus:
        // Callers should use addSupportedToken then setTokenLiquidationBonus if needed

        /// Sets per-token liquidation bonus fraction (0.0 to 1.0). E.g., 0.05 means +5% seize bonus.
        access(EGovernance) fun setTokenLiquidationBonus(tokenType: Type, bonus: UFix64) {
            pre {
                self.isTokenSupported(tokenType: tokenType):
                    "Unsupported token type \(tokenType.identifier)"
                bonus >= 0.0 && bonus <= 1.0:
                    "Liquidation bonus must be between 0 and 1"
            }
            self.liquidationBonus[tokenType] = bonus
        }

        /// Updates the insurance rate for a given token (fraction in [0,1])
        access(EGovernance) fun setInsuranceRate(tokenType: Type, insuranceRate: UFix64) {
            pre {
                self.isTokenSupported(tokenType: tokenType):
                    "Unsupported token type \(tokenType.identifier)"
                insuranceRate >= 0.0 && insuranceRate < 1.0:
                    "insuranceRate must be in range [0, 1)"
                insuranceRate + (self.getStabilityFeeRate(tokenType: tokenType) ?? 0.0) < 1.0:
                    "insuranceRate + stabilityFeeRate must be in range [0, 1) to avoid underflow in credit rate calculation"
            }
            let tsRef = &self.globalLedger[tokenType] as auth(EImplementation) &TokenState?
                ?? panic("Invariant: token state missing")

            // Validate constraint: non-zero rate requires swapper
            if insuranceRate > 0.0 {
                assert(
                    tsRef.insuranceSwapper != nil, 
                    message:"Cannot set non-zero insurance rate without an insurance swapper configured for \(tokenType.identifier)",
                )
            }
            tsRef.setInsuranceRate(insuranceRate)

            emit InsuranceRateUpdated(
                poolUUID: self.uuid,
                tokenType: tokenType.identifier,
                insuranceRate: insuranceRate,
            )
        }

        /// Sets the insurance swapper for a given token type (must swap from tokenType to MOET)
        access(EGovernance) fun setInsuranceSwapper(tokenType: Type, swapper: {DeFiActions.Swapper}?) {
            pre {
                self.isTokenSupported(tokenType: tokenType): "Unsupported token type"
            }
            let tsRef = &self.globalLedger[tokenType] as auth(EImplementation) &TokenState?
                ?? panic("Invariant: token state missing")   

            if let swapper = swapper {
                // Validate swapper types match
                assert(swapper.inType() == tokenType, message: "Swapper input type must match token type")
                assert(swapper.outType() == Type<@MOET.Vault>(), message: "Swapper output type must be MOET")
            
            } else {
                // cannot remove swapper if insurance rate > 0
                assert(
                    tsRef.insuranceRate == 0.0,
                    message: "Cannot remove insurance swapper while insurance rate is non-zero for \(tokenType.identifier)"
                )
            }

            tsRef.setInsuranceSwapper(swapper)
        }

        /// Manually triggers insurance collection for a given token type.
        /// This is useful for governance to collect accrued insurance on-demand.
        /// Insurance is calculated based on time elapsed since last collection.
        access(EGovernance) fun collectInsurance(tokenType: Type) {
            pre {
                self.isTokenSupported(tokenType: tokenType): "Unsupported token type"
            }
            self.updateInterestRatesAndCollectInsurance(tokenType: tokenType)
        }

        /// Updates the per-deposit limit fraction for a given token (fraction in [0,1])
        access(EGovernance) fun setDepositLimitFraction(tokenType: Type, fraction: UFix64) {
            pre {
                self.isTokenSupported(tokenType: tokenType):
                    "Unsupported token type \(tokenType.identifier)"
                fraction > 0.0 && fraction <= 1.0:
                    "fraction must be in (0,1]"
            }
            let tsRef = &self.globalLedger[tokenType] as auth(EImplementation) &TokenState?
                ?? panic("Invariant: token state missing")
            tsRef.setDepositLimitFraction(fraction)
        }

        /// Updates the deposit rate for a given token (tokens per hour)
        access(EGovernance) fun setDepositRate(tokenType: Type, hourlyRate: UFix64) {
            pre {
                self.isTokenSupported(tokenType: tokenType): "Unsupported token type"
            }
            let tsRef = &self.globalLedger[tokenType] as auth(EImplementation) &TokenState?
                ?? panic("Invariant: token state missing")
            tsRef.setDepositRate(hourlyRate)
        }

        /// Updates the deposit capacity cap for a given token
        access(EGovernance) fun setDepositCapacityCap(tokenType: Type, cap: UFix64) {
            pre {
                self.isTokenSupported(tokenType: tokenType): "Unsupported token type"
            }
            let tsRef = &self.globalLedger[tokenType] as auth(EImplementation) &TokenState?
                ?? panic("Invariant: token state missing")
            tsRef.setDepositCapacityCap(cap)
        }

        /// Updates the stability fee rate for a given token (fraction in [0,1]).
        ///
        /// @param tokenTypeIdentifier: The fully qualified type identifier of the token (e.g., "A.0x1.FlowToken.Vault")
        /// @param stabilityFeeRate: The fee rate as a fraction in [0, 1]
        ///
        ///
        /// Emits: StabilityFeeRateUpdated
        access(EGovernance) fun setStabilityFeeRate(tokenType: Type, stabilityFeeRate: UFix64) {
            pre {
                self.isTokenSupported(tokenType: tokenType):
                    "Unsupported token type \(tokenType.identifier)"
                stabilityFeeRate >= 0.0 && stabilityFeeRate < 1.0:
                    "stability fee rate must be in range [0, 1)"
                stabilityFeeRate + (self.getInsuranceRate(tokenType: tokenType) ?? 0.0) < 1.0:
                    "stabilityFeeRate + insuranceRate must be in range [0, 1) to avoid underflow in credit rate calculation"
            }
            let tsRef = &self.globalLedger[tokenType] as auth(EImplementation) &TokenState?
                ?? panic("Invariant: token state missing")
            tsRef.setStabilityFeeRate(stabilityFeeRate)
            
            emit StabilityFeeRateUpdated(
                poolUUID: self.uuid,
                tokenType: tokenType.identifier,
                stabilityFeeRate: stabilityFeeRate,
            )
        }

        /// Withdraws stability funds collected from the stability fee for a given token
        ///
        /// Emits: StabilityFundWithdrawn
        access(EGovernance) fun withdrawStabilityFund(tokenType: Type, amount: UFix64, recipient: &{FungibleToken.Receiver}) {
            pre {
                self.stabilityFunds[tokenType] != nil: "No stability fund exists for token type \(tokenType.identifier)"
                amount > 0.0: "Withdrawal amount must be positive"
            }
            let fundRef = (&self.stabilityFunds[tokenType] as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?)!
            assert(
                fundRef.balance >= amount,
                message: "Insufficient stability fund balance. Available: \(fundRef.balance), requested: \(amount)"
            )
            
            let withdrawn <- fundRef.withdraw(amount: amount)
            recipient.deposit(from: <-withdrawn)

            emit StabilityFundWithdrawn(
                poolUUID: self.uuid,
                tokenType: tokenType.identifier,
                amount: amount,
            )
        }

        /// Manually triggers fee collection for a given token type.
        /// This is useful for governance to collect accrued stability on-demand.
        /// Fee is calculated based on time elapsed since last collection.
        access(EGovernance) fun collectStability(tokenType: Type) {
            pre {
                self.isTokenSupported(tokenType: tokenType): "Unsupported token type"
            }
            self.updateInterestRatesAndCollectStability(tokenType: tokenType)
        }

        /// Regenerates deposit capacity for all supported token types
        /// Each token type's capacity regenerates independently based on its own depositRate,
        /// approximately once per hour, up to its respective depositCapacityCap
        /// When capacity regenerates, user deposit usage is reset for that token type
        access(EImplementation) fun regenerateAllDepositCapacities() {
            for tokenType in self.globalLedger.keys {
                let tsRef = &self.globalLedger[tokenType] as auth(EImplementation) &TokenState?
                    ?? panic("Invariant: token state missing")
                tsRef.regenerateDepositCapacity()
            }
        }

        /// Updates the interest curve for a given token
        /// This allows governance to change the interest rate model for a token after it has been added
        /// to the pool. For example, switching from a fixed rate to a kink-based model, or updating
        /// the parameters of an existing kink model.
        ///
        /// Important: Before changing the curve, we must first compound any accrued interest at the
        /// OLD rate. Otherwise, interest that accrued since lastUpdate would be calculated using the
        /// new rate, which would be incorrect.
        access(EGovernance) fun setInterestCurve(tokenType: Type, interestCurve: {InterestCurve}) {
            pre {
                self.isTokenSupported(tokenType: tokenType): "Unsupported token type"
            }
            // First, update interest indices to compound any accrued interest at the OLD rate
            // This "finalizes" all interest accrued up to this moment before switching curves
            let tsRef = self._borrowUpdatedTokenState(type: tokenType)
            // Now safe to set the new curve - subsequent interest will accrue at the new rate
            tsRef.setInterestCurve(interestCurve)
            emit InterestCurveUpdated(
                poolUUID: self.uuid,
                tokenType: tokenType.identifier,
                curveType: interestCurve.getType().identifier
            )
        }

        /// Enables or disables verbose logging inside the Pool for testing and diagnostics
        access(EGovernance) fun setDebugLogging(_ enabled: Bool) {
            self.debugLogging = enabled
        }

        /// Rebalances the position to the target health value, if the position is under- or over-collateralized,
        /// as defined by the position-specific min/max health thresholds.
        /// If force=true, the position will be rebalanced regardless of its current health.
        ///
        /// When rebalancing, funds are withdrawn from the position's topUpSource or deposited to its drawDownSink.
        /// Rebalancing is done on a best effort basis (even when force=true). If the position has no sink/source,
        /// of either cannot accept/provide sufficient funds for rebalancing, the rebalance will still occur but will
        /// not cause the position to reach its target health.
        access(EPosition) fun rebalancePosition(pid: UInt64, force: Bool) {
            if self.debugLogging {
                log("    [CONTRACT] rebalancePosition(pid: \(pid), force: \(force))")
            }
            let position = self._borrowPosition(pid: pid)
            let balanceSheet = self._getUpdatedBalanceSheet(pid: pid)

            if !force && (position.minHealth <= balanceSheet.health && balanceSheet.health <= position.maxHealth) {
                // We aren't forcing the update, and the position is already between its desired min and max. Nothing to do!
                return
            }

            if balanceSheet.health < position.targetHealth {
                // The position is undercollateralized,
                // see if the source can get more collateral to bring it up to the target health.
                if let topUpSource = position.topUpSource {
                    let topUpSource = topUpSource as auth(FungibleToken.Withdraw) &{DeFiActions.Source}
                    let idealDeposit = self.fundsRequiredForTargetHealth(
                        pid: pid,
                        type: topUpSource.getSourceType(),
                        targetHealth: position.targetHealth
                    )
                    if self.debugLogging {
                        log("    [CONTRACT] idealDeposit: \(idealDeposit)")
                    }

                    let pulledVault <- topUpSource.withdrawAvailable(maxAmount: idealDeposit)

                    emit Rebalanced(
                        pid: pid,
                        poolUUID: self.uuid,
                        atHealth: balanceSheet.health,
                        amount: pulledVault.balance,
                        fromUnder: true
                        )

                    self.depositAndPush(
                        pid: pid,
                        from: <-pulledVault,
                        pushToDrawDownSink: false
                    )
                }
            } else if balanceSheet.health > position.targetHealth {
                // The position is overcollateralized,
                // we'll withdraw funds to match the target health and offer it to the sink.
                if let drawDownSink = position.drawDownSink {
                    let drawDownSink = drawDownSink as auth(FungibleToken.Withdraw) &{DeFiActions.Sink}
                    let sinkType = drawDownSink.getSinkType()
                    let idealWithdrawal = self.fundsAvailableAboveTargetHealth(
                        pid: pid,
                        type: sinkType,
                        targetHealth: position.targetHealth
                    )
                    if self.debugLogging {
                        log("    [CONTRACT] idealWithdrawal: \(idealWithdrawal)")
                    }

                    // Compute how many tokens of the sink's type are available to hit our target health.
                    let sinkCapacity = drawDownSink.minimumCapacity()
                    let sinkAmount = (idealWithdrawal > sinkCapacity) ? sinkCapacity : idealWithdrawal

                    // TODO(jord): we enforce in setDrawDownSink that the type is MOET -> we should panic here if that does not hold (currently silently fail)
                    if sinkAmount > 0.0 && sinkType == Type<@MOET.Vault>() {
                        let tokenState = self._borrowUpdatedTokenState(type: Type<@MOET.Vault>())
                        if position.balances[Type<@MOET.Vault>()] == nil {
                            position.balances[Type<@MOET.Vault>()] = InternalBalance(
                                direction: BalanceDirection.Credit,
                                scaledBalance: 0.0
                            )
                        }
                        // record the withdrawal and mint the tokens
                        let uintSinkAmount = UFix128(sinkAmount)
                        position.balances[Type<@MOET.Vault>()]!.recordWithdrawal(
                            amount: uintSinkAmount,
                            tokenState: tokenState
                        )
                        let sinkVault <- FlowCreditMarket._borrowMOETMinter().mintTokens(amount: sinkAmount)

                        emit Rebalanced(
                            pid: pid,
                            poolUUID: self.uuid,
                            atHealth: balanceSheet.health,
                            amount: sinkVault.balance,
                            fromUnder: false
                        )

                        // Push what we can into the sink, and redeposit the rest
                        drawDownSink.depositCapacity(from: &sinkVault as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
                        if sinkVault.balance > 0.0 {
                            self.depositAndPush(
                                pid: pid,
                                from: <-sinkVault,
                                pushToDrawDownSink: false
                            )
                        } else {
                            Burner.burn(<-sinkVault)
                        }
                    }
                }
            }
        }

        /// Executes asynchronous updates on positions that have been queued up to the lesser of the queue length or
        /// the configured positionsProcessedPerCallback value
        access(EImplementation) fun asyncUpdate() {
            // TODO: In the production version, this function should only process some positions (limited by positionsProcessedPerCallback) AND
            // it should schedule each update to run in its own callback, so a revert() call from one update (for example, if a source or
            // sink aborts) won't prevent other positions from being updated.
            var processed: UInt64 = 0
            while self.positionsNeedingUpdates.length > 0 && processed < self.positionsProcessedPerCallback {
                let pid = self.positionsNeedingUpdates.removeFirst()
                self.asyncUpdatePosition(pid: pid)
                self._queuePositionForUpdateIfNecessary(pid: pid)
                processed = processed + 1
            }
        }

        /// Executes an asynchronous update on the specified position
        access(EImplementation) fun asyncUpdatePosition(pid: UInt64) {
            let position = self._borrowPosition(pid: pid)

            // First check queued deposits, their addition could affect the rebalance we attempt later
            for depositType in position.queuedDeposits.keys {
                let queuedVault <- position.queuedDeposits.remove(key: depositType)!
                let queuedAmount = queuedVault.balance
                let depositTokenState = self._borrowUpdatedTokenState(type: depositType)
                let maxDeposit = depositTokenState.depositLimit()

                if maxDeposit >= queuedAmount {
                    // We can deposit all of the queued deposit, so just do it and remove it from the queue
                    self.depositAndPush(
                        pid: pid,
                        from: <-queuedVault,
                        pushToDrawDownSink: false
                    )
                } else {
                    // We can only deposit part of the queued deposit, so do that and leave the rest in the queue
                    // for the next time we run.
                    let depositVault <- queuedVault.withdraw(amount: maxDeposit)
                    self.depositAndPush(
                        pid: pid,
                        from: <-depositVault,
                        pushToDrawDownSink: false
                    )

                    // We need to update the queued vault to reflect the amount we used up
                    position.queuedDeposits[depositType] <-! queuedVault
                }
            }

            // Now that we've deposited a non-zero amount of any queued deposits, we can rebalance
            // the position if necessary.
            self.rebalancePosition(pid: pid, force: false)
        }

        /// Updates interest rates for a token and collects stability fee.
        /// This method should be called periodically to ensure rates are current and fee amounts are collected.
        ///
        /// @param tokenType: The token type to update rates for
        access(self) fun updateInterestRatesAndCollectStability(tokenType: Type) {
            let tokenState = self._borrowUpdatedTokenState(type: tokenType)
            tokenState.updateInterestRates()

            // Ensure reserves exist for this token type
            if self.reserves[tokenType] == nil {
                return
            }

            // Get reference to reserves
            let reserveRef = (&self.reserves[tokenType] as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?)!

            // Collect stability and get token vault
            if let collectedVault <- tokenState.collectStability(reserveVault: reserveRef) {  
                let collectedBalance = collectedVault.balance     
                // Deposit collected token into stability fund
                if self.stabilityFunds[tokenType] == nil {
                    self.stabilityFunds[tokenType] <-! collectedVault
                } else {
                    let fundRef = (&self.stabilityFunds[tokenType] as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?)!
                    fundRef.deposit(from: <-collectedVault)
                }
                
                emit StabilityFeeCollected(
                    poolUUID: self.uuid,
                    tokenType: tokenType.identifier,
                    stabilityAmount: collectedBalance,
                    collectionTime: tokenState.lastStabilityFeeCollectionTime
                )
            }
        }

        ////////////////
        // INTERNAL
        ////////////////

        /// Queues a position for asynchronous updates if the position has been marked as requiring an update
        access(self) fun _queuePositionForUpdateIfNecessary(pid: UInt64) {
            if self.positionsNeedingUpdates.contains(pid) {
                // If this position is already queued for an update, no need to check anything else
                return
            }

            // If this position is not already queued for an update, we need to check if it needs one
            let position = self._borrowPosition(pid: pid)

            if position.queuedDeposits.length > 0 {
                // This position has deposits that need to be processed, so we need to queue it for an update
                self.positionsNeedingUpdates.append(pid)
                return
            }

            let positionHealth = self.positionHealth(pid: pid)

            if positionHealth < position.minHealth || positionHealth > position.maxHealth {
                // This position is outside the configured health bounds, we queue it for an update
                self.positionsNeedingUpdates.append(pid)
                return
            }
        }

        /// Returns a position's BalanceSheet containing its effective collateral and debt as well as its current health
        /// TODO(jord): in all cases callers already are calling _borrowPosition, more efficient to pass in PositionView?
        access(self) fun _getUpdatedBalanceSheet(pid: UInt64): BalanceSheet {
            let position = self._borrowPosition(pid: pid)

            // Get the position's collateral and debt values in terms of the default token.
            var effectiveCollateral: UFix128 = 0.0
            var effectiveDebt: UFix128 = 0.0

            for type in position.balances.keys {
                let balance = position.balances[type]!
                let tokenState = self._borrowUpdatedTokenState(type: type)

                switch balance.direction {
                    case BalanceDirection.Credit:
                        let trueBalance = FlowCreditMarket.scaledBalanceToTrueBalance(
                            balance.scaledBalance,
                            interestIndex: tokenState.creditInterestIndex
                        )

                        let convertedPrice = UFix128(self.priceOracle.price(ofToken: type)!)
                        let value = convertedPrice * trueBalance

                        let convertedCollateralFactor = UFix128(self.collateralFactor[type]!)
                        effectiveCollateral = effectiveCollateral + (value * convertedCollateralFactor)

                    case BalanceDirection.Debit:
                        let trueBalance = FlowCreditMarket.scaledBalanceToTrueBalance(
                            balance.scaledBalance,
                            interestIndex: tokenState.debitInterestIndex
                        )

                        let convertedPrice = UFix128(self.priceOracle.price(ofToken: type)!)
                        let value = convertedPrice * trueBalance

                        let convertedBorrowFactor = UFix128(self.borrowFactor[type]!)
                        effectiveDebt = effectiveDebt + (value / convertedBorrowFactor)

                }
            }

            return BalanceSheet(
                effectiveCollateral: effectiveCollateral,
                effectiveDebt: effectiveDebt
            )
        }

        /// A convenience function that returns a reference to a particular token state, making sure it's up-to-date for
        /// the passage of time. This should always be used when accessing a token state to avoid missing interest
        /// updates (duplicate calls to updateForTimeChange() are a nop within a single block).
        access(self) fun _borrowUpdatedTokenState(type: Type): auth(EImplementation) &TokenState {
            let state = &self.globalLedger[type]! as auth(EImplementation) &TokenState
            state.updateForTimeChange()
            return state
        }

        /// Updates interest rates for a token and collects insurance if a swapper is configured for the token.
        /// This method should be called periodically to ensure rates are current and insurance is collected.
        ///
        /// @param tokenType: The token type to update rates for
        access(self) fun updateInterestRatesAndCollectInsurance(tokenType: Type) {
            let tokenState = self._borrowUpdatedTokenState(type: tokenType)
            tokenState.updateInterestRates()
            
            // Collect insurance if swapper is configured
            // Ensure reserves exist for this token type
            if self.reserves[tokenType] == nil {
                return
            }

            // Get reference to reserves
            if let reserveRef = (&self.reserves[tokenType] as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?) {
                // Collect insurance and get MOET vault
                if let collectedMOET <- tokenState.collectInsurance(reserveVault: reserveRef) {
                    let collectedMOETBalance = collectedMOET.balance
                    // Deposit collected MOET into insurance fund
                    self.insuranceFund.deposit(from: <-collectedMOET)

                    emit InsuranceFeeCollected(
                        poolUUID: self.uuid,
                        tokenType: tokenType.identifier,
                        insuranceAmount: collectedMOETBalance,
                        collectionTime: tokenState.lastInsuranceCollectionTime
                    )
                }
            }
        }

        /// Returns an authorized reference to the requested InternalPosition or `nil` if the position does not exist
        access(self) view fun _borrowPosition(pid: UInt64): auth(EImplementation) &InternalPosition {
            return &self.positions[pid] as auth(EImplementation) &InternalPosition?
                ?? panic("Invalid position ID \(pid) - could not find an InternalPosition with the requested ID in the Pool")
        }

        /// Build a PositionView for the given position ID.
        access(all) fun buildPositionView(pid: UInt64): FlowCreditMarket.PositionView {
            let position = self._borrowPosition(pid: pid)
            let snaps: {Type: FlowCreditMarket.TokenSnapshot} = {}
            let balancesCopy = position.copyBalances()
            for t in position.balances.keys {
                let tokenState = self._borrowUpdatedTokenState(type: t)
                snaps[t] = FlowCreditMarket.TokenSnapshot(
                    price: UFix128(self.priceOracle.price(ofToken: t)!),
                    credit: tokenState.creditInterestIndex,
                    debit: tokenState.debitInterestIndex,
                    risk: FlowCreditMarket.RiskParams(
                        collateralFactor: UFix128(self.collateralFactor[t]!),
                        borrowFactor: UFix128(self.borrowFactor[t]!),
                        liquidationBonus: UFix128(self.liquidationBonus[t]!)
                    )
                )
            }
            return FlowCreditMarket.PositionView(
                balances: balancesCopy,
                snapshots: snaps,
                defaultToken: self.defaultToken,
                min: position.minHealth,
                max: position.maxHealth
            )
        }

        access(EGovernance) fun setPriceOracle(_ newOracle: {DeFiActions.PriceOracle}) {
            pre {
                newOracle.unitOfAccount() == self.defaultToken:
                    "Price oracle must return prices in terms of the pool's default token"
            }
            self.priceOracle = newOracle
            self.positionsNeedingUpdates = self.positions.keys

            emit PriceOracleUpdated(
                poolUUID: self.uuid,
                newOracleType: newOracle.getType().identifier
            )
        }

        access(all) fun getDefaultToken(): Type {
            return self.defaultToken
        }
        
        /// Returns the deposit capacity and deposit capacity cap for a given token type
        access(all) fun getDepositCapacityInfo(type: Type): {String: UFix64} {
            let tokenState = self._borrowUpdatedTokenState(type: type)
            return {
                "depositCapacity": tokenState.depositCapacity,
                "depositCapacityCap": tokenState.depositCapacityCap,
                "depositRate": tokenState.depositRate,
                "depositLimitFraction": tokenState.depositLimitFraction,
                "lastDepositCapacityUpdate": tokenState.lastDepositCapacityUpdate
            }
        }
    }

    /// PoolFactory
    ///
    /// Resource enabling the contract account to create the contract's Pool. This pattern is used in place of contract
    /// methods to ensure limited access to pool creation. While this could be done in contract's init, doing so here
    /// will allow for the setting of the Pool's PriceOracle without the introduction of a concrete PriceOracle defining
    /// contract which would include an external contract dependency.
    ///
    access(all) resource PoolFactory {
        /// Creates the contract-managed Pool and saves it to the canonical path, reverting if one is already stored
        access(all) fun createPool(
        	defaultToken: Type,
        	priceOracle: {DeFiActions.PriceOracle},
        	dex: {DeFiActions.SwapperProvider}
        ) {
            pre {
                FlowCreditMarket.account.storage.type(at: FlowCreditMarket.PoolStoragePath) == nil:
                    "Storage collision - Pool has already been created & saved to \(FlowCreditMarket.PoolStoragePath)"
            }
            let pool <- create Pool(
            	defaultToken: defaultToken,
            	priceOracle: priceOracle,
            	dex: dex
            )
            FlowCreditMarket.account.storage.save(<-pool, to: FlowCreditMarket.PoolStoragePath)
            let cap = FlowCreditMarket.account.capabilities.storage.issue<&Pool>(FlowCreditMarket.PoolStoragePath)
            FlowCreditMarket.account.capabilities.unpublish(FlowCreditMarket.PoolPublicPath)
            FlowCreditMarket.account.capabilities.publish(cap, at: FlowCreditMarket.PoolPublicPath)
        }
    }

    /// Position
    ///
    /// A Position is an external object representing ownership of value deposited to the protocol. From a Position, an
    /// actor can deposit and withdraw funds as well as construct DeFiActions components enabling value flows in and out
    /// of the Position from within the context of DeFiActions stacks.
    ///
    // TODO: Consider making this a resource given how critical it is to accessing a loan
    access(all) struct Position {

        /// The unique ID of the Position used to track deposits and withdrawals to the Pool
        access(self) let id: UInt64

        /// An authorized Capability to which the Position was opened
        access(self) let pool: Capability<auth(EPosition, EParticipant) &Pool>

        init(
            id: UInt64,
            pool: Capability<auth(EPosition, EParticipant) &Pool>
        ) {
            pre {
                pool.check():
                    "Invalid Pool Capability provided - cannot construct Position"
            }
            self.id = id
            self.pool = pool
        }

        /// Returns the balances (both positive and negative) for all tokens in this position.
        access(all) fun getBalances(): [PositionBalance] {
            let pool = self.pool.borrow()!
            return pool.getPositionDetails(pid: self.id).balances
        }

        /// Returns the balance available for withdrawal of a given Vault type. If pullFromTopUpSource is true, the
        /// calculation will be made assuming the position is topped up if the withdrawal amount puts the Position
        /// below its min health. If pullFromTopUpSource is false, the calculation will return the balance currently
        /// available without topping up the position.
        access(all) fun availableBalance(type: Type, pullFromTopUpSource: Bool): UFix64 {
            let pool = self.pool.borrow()!
            return pool.availableBalance(pid: self.id, type: type, pullFromTopUpSource: pullFromTopUpSource)
        }

        /// Returns the current health of the position
        access(all) fun getHealth(): UFix128 {
            let pool = self.pool.borrow()!
            return pool.positionHealth(pid: self.id)
        }

        /// Returns the Position's target health (unitless ratio ≥ 1.0)
        access(all) fun getTargetHealth(): UFix64 {
            let pool = self.pool.borrow()!
            let uint = pool.readTargetHealth(pid: self.id)
            return FlowCreditMarketMath.toUFix64Round(uint)
        }

        /// Sets the target health of the Position
        access(all) fun setTargetHealth(targetHealth: UFix64) {
            let pool = self.pool.borrow()!
            let uint = UFix128(targetHealth)
            pool.writeTargetHealth(pid: self.id, targetHealth: uint)
        }

        /// Returns the minimum health of the Position
        access(all) fun getMinHealth(): UFix64 {
            let pool = self.pool.borrow()!
            let uint = pool.readMinHealth(pid: self.id)
            return FlowCreditMarketMath.toUFix64Round(uint)
        }

        /// Sets the minimum health of the Position
        access(all) fun setMinHealth(minHealth: UFix64) {
            let pool = self.pool.borrow()!
            let uint = UFix128(minHealth)
            pool.writeMinHealth(pid: self.id, minHealth: uint)
        }

        /// Returns the maximum health of the Position
        access(all) fun getMaxHealth(): UFix64 {
            let pool = self.pool.borrow()!
            let uint = pool.readMaxHealth(pid: self.id)
            return FlowCreditMarketMath.toUFix64Round(uint)
        }

        /// Sets the maximum health of the position
        access(all) fun setMaxHealth(maxHealth: UFix64) {
            let pool = self.pool.borrow()!
            let uint = UFix128(maxHealth)
            pool.writeMaxHealth(pid: self.id, maxHealth: uint)
        }

        /// Returns the maximum amount of the given token type that could be deposited into this position
        access(all) fun getDepositCapacity(type: Type): UFix64 {
            // There's no limit on deposits from the position's perspective
            return UFix64.max
        }

        /// Deposits funds to the Position without pushing to the drawDownSink
        /// if the deposit puts the Position above its maximum health
        access(EParticipant) fun deposit(from: @{FungibleToken.Vault}) {
            self.depositAndPush(
                from: <-from,
                pushToDrawDownSink: false
            )
        }

        /// Deposits funds to the Position enabling the caller to configure whether excess value
        /// should be pushed to the drawDownSink if the deposit puts the Position above its maximum health
        access(EParticipant) fun depositAndPush(
            from: @{FungibleToken.Vault},
            pushToDrawDownSink: Bool
        ) {
            let pool = self.pool.borrow()!
            pool.depositAndPush(
                pid: self.id,
                from: <-from,
                pushToDrawDownSink: pushToDrawDownSink
            )
        }

        /// Withdraws funds from the Position without pulling from the topUpSource
        /// if the deposit puts the Position below its minimum health
        access(FungibleToken.Withdraw) fun withdraw(type: Type, amount: UFix64): @{FungibleToken.Vault} {
            return <- self.withdrawAndPull(
                type: type,
                amount: amount,
                pullFromTopUpSource: false
            )
        }

        /// Withdraws funds from the Position enabling the caller to configure whether insufficient value
        /// should be pulled from the topUpSource if the deposit puts the Position below its minimum health
        access(FungibleToken.Withdraw) fun withdrawAndPull(
            type: Type,
            amount: UFix64,
            pullFromTopUpSource: Bool
        ): @{FungibleToken.Vault} {
            let pool = self.pool.borrow()!
            return <- pool.withdrawAndPull(
                pid: self.id,
                type: type,
                amount: amount,
                pullFromTopUpSource: pullFromTopUpSource
            )
        }

        /// Returns a new Sink for the given token type that will accept deposits of that token
        /// and update the position's collateral and/or debt accordingly.
        ///
        /// Note that calling this method multiple times will create multiple sinks,
        /// each of which will continue to work regardless of how many other sinks have been created.
        access(all) fun createSink(type: Type): {DeFiActions.Sink} {
            // create enhanced sink with pushToDrawDownSink option
            return self.createSinkWithOptions(
                type: type,
                pushToDrawDownSink: false
            )
        }

        /// Returns a new Sink for the given token type and pushToDrawDownSink option
        /// that will accept deposits of that token and update the position's collateral and/or debt accordingly.
        ///
        /// Note that calling this method multiple times will create multiple sinks,
        /// each of which will continue to work regardless of how many other sinks have been created.
        access(all) fun createSinkWithOptions(
            type: Type,
            pushToDrawDownSink: Bool
        ): {DeFiActions.Sink} {
            let pool = self.pool.borrow()!
            return PositionSink(
                id: self.id,
                pool: self.pool,
                type: type,
                pushToDrawDownSink: pushToDrawDownSink
            )
        }

        /// Returns a new Source for the given token type that will service withdrawals of that token
        /// and update the position's collateral and/or debt accordingly.
        ///
        /// Note that calling this method multiple times will create multiple sources,
        /// each of which will continue to work regardless of how many other sources have been created.
        access(FungibleToken.Withdraw) fun createSource(type: Type): {DeFiActions.Source} {
            // Create enhanced source with pullFromTopUpSource = true
            return self.createSourceWithOptions(
                type: type,
                pullFromTopUpSource: false
            )
        }

        /// Returns a new Source for the given token type and pullFromTopUpSource option
        /// that will service withdrawals of that token and update the position's collateral and/or debt accordingly.
        ///
        /// Note that calling this method multiple times will create multiple sources,
        /// each of which will continue to work regardless of how many other sources have been created.
        access(FungibleToken.Withdraw) fun createSourceWithOptions(
            type: Type,
            pullFromTopUpSource: Bool
        ): {DeFiActions.Source} {
            let pool = self.pool.borrow()!
            return PositionSource(
                id: self.id,
                pool: self.pool,
                type: type,
                pullFromTopUpSource: pullFromTopUpSource
            )
        }

        /// Provides a sink to the Position that will have tokens proactively pushed into it
        /// when the position has excess collateral.
        /// (Remember that sinks do NOT have to accept all tokens provided to them;
        /// the sink can choose to accept only some (or none) of the tokens provided,
        /// leaving the position overcollateralized).
        ///
        /// Each position can have only one sink, and the sink must accept the default token type
        /// configured for the pool. Providing a new sink will replace the existing sink.
        ///
        /// Pass nil to configure the position to not push tokens when the Position exceeds its maximum health.
        access(FungibleToken.Withdraw) fun provideSink(sink: {DeFiActions.Sink}?) {
            let pool = self.pool.borrow()!
            pool.provideDrawDownSink(pid: self.id, sink: sink)
        }

        /// Provides a source to the Position that will have tokens proactively pulled from it
        /// when the position has insufficient collateral.
        /// If the source can cover the position's debt, the position will not be liquidated.
        ///
        /// Each position can have only one source, and the source must accept the default token type
        /// configured for the pool. Providing a new source will replace the existing source.
        ///
        /// Pass nil to configure the position to not pull tokens.
        access(EParticipant) fun provideSource(source: {DeFiActions.Source}?) {
            let pool = self.pool.borrow()!
            pool.provideTopUpSource(pid: self.id, source: source)
        }
    }

    /// PositionSink
    ///
    /// A DeFiActions connector enabling deposits to a Position from within a DeFiActions stack.
    /// This Sink is intended to be constructed from a Position object.
    ///
    access(all) struct PositionSink: DeFiActions.Sink {

        /// An optional DeFiActions.UniqueIdentifier that identifies this Sink with the DeFiActions stack its a part of
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        /// An authorized Capability on the Pool for which the related Position is in
        access(self) let pool: Capability<auth(EPosition) &Pool>

        /// The ID of the position in the Pool
        access(self) let positionID: UInt64

        /// The Type of Vault this Sink accepts
        access(self) let type: Type

        /// Whether deposits through this Sink to the Position should push available value to the Position's
        /// drawDownSink
        access(self) let pushToDrawDownSink: Bool

        init(
            id: UInt64,
            pool: Capability<auth(EPosition) &Pool>,
            type: Type,
            pushToDrawDownSink: Bool
        ) {
            self.uniqueID = nil
            self.positionID = id
            self.pool = pool
            self.type = type
            self.pushToDrawDownSink = pushToDrawDownSink
        }

        /// Returns the Type of Vault this Sink accepts on deposits
        access(all) view fun getSinkType(): Type {
            return self.type
        }

        /// Returns the minimum capacity this Sink can accept as deposits
        access(all) fun minimumCapacity(): UFix64 {
            return self.pool.check() ? UFix64.max : 0.0
        }

        /// Deposits the funds from the provided Vault reference to the related Position
        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            if let pool = self.pool.borrow() {
                pool.depositAndPush(
                    pid: self.positionID,
                    from: <-from.withdraw(amount: from.balance),
                    pushToDrawDownSink: self.pushToDrawDownSink
                )
            }
        }

        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
                innerComponents: []
            )
        }

        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }

        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) {
            self.uniqueID = id
        }
    }

    /// PositionSource
    ///
    /// A DeFiActions connector enabling withdrawals from a Position from within a DeFiActions stack.
    /// This Source is intended to be constructed from a Position object.
    ///
    access(all) struct PositionSource: DeFiActions.Source {

        /// An optional DeFiActions.UniqueIdentifier that identifies this Sink with the DeFiActions stack its a part of
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        /// An authorized Capability on the Pool for which the related Position is in
        access(self) let pool: Capability<auth(EPosition) &Pool>

        /// The ID of the position in the Pool
        access(self) let positionID: UInt64

        /// The Type of Vault this Sink provides
        access(self) let type: Type

        /// Whether withdrawals through this Sink from the Position should pull value from the Position's topUpSource
        /// in the event the withdrawal puts the position under its target health
        access(self) let pullFromTopUpSource: Bool

        init(
            id: UInt64,
            pool: Capability<auth(EPosition) &Pool>,
            type: Type,
            pullFromTopUpSource: Bool
        ) {
            self.uniqueID = nil
            self.positionID = id
            self.pool = pool
            self.type = type
            self.pullFromTopUpSource = pullFromTopUpSource
        }

        /// Returns the Type of Vault this Source provides on withdrawals
        access(all) view fun getSourceType(): Type {
            return self.type
        }

        /// Returns the minimum available this Source can provide on withdrawal
        access(all) fun minimumAvailable(): UFix64 {
            if !self.pool.check() {
                return 0.0
            }

            let pool = self.pool.borrow()!
            return pool.availableBalance(
                pid: self.positionID,
                type: self.type,
                pullFromTopUpSource: self.pullFromTopUpSource
            )
        }

        /// Withdraws up to the max amount as the sourceType Vault
        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            if !self.pool.check() {
                return <- DeFiActionsUtils.getEmptyVault(self.type)
            }

            let pool = self.pool.borrow()!
            let available = pool.availableBalance(
                pid: self.positionID,
                type: self.type,
                pullFromTopUpSource: self.pullFromTopUpSource
            )
            let withdrawAmount = (available > maxAmount) ? maxAmount : available
            if withdrawAmount > 0.0 {
                return <- pool.withdrawAndPull(
                    pid: self.positionID,
                    type: self.type,
                    amount: withdrawAmount,
                    pullFromTopUpSource: self.pullFromTopUpSource
                )
            } else {
                // Create an empty vault - this is a limitation we need to handle properly
                return <- DeFiActionsUtils.getEmptyVault(self.type)
            }
        }

        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
                innerComponents: []
            )
        }

        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }

        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) {
            self.uniqueID = id
        }
    }

    /// BalanceDirection
    ///
    /// The direction of a given balance
    access(all) enum BalanceDirection: UInt8 {

        /// Denotes that a balance that is withdrawable from the protocol
        access(all) case Credit

        /// Denotes that a balance that is due to the protocol
        access(all) case Debit
    }

    /// PositionBalance
    ///
    /// A structure returned externally to report a position's balance for a particular token.
    /// This structure is NOT used internally.
    access(all) struct PositionBalance {

        /// The token type for which the balance details relate to
        access(all) let vaultType: Type

        /// Whether the balance is a Credit or Debit
        access(all) let direction: BalanceDirection

        /// The balance of the token for the related Position
        access(all) let balance: UFix64

        init(
            vaultType: Type,
            direction: BalanceDirection,
            balance: UFix64
        ) {
            self.vaultType = vaultType
            self.direction = direction
            self.balance = balance
        }
    }

    /// PositionDetails
    ///
    /// A structure returned externally to report all of the details associated with a position.
    /// This structure is NOT used internally.
    access(all) struct PositionDetails {

        /// Balance details about each Vault Type deposited to the related Position
        access(all) let balances: [PositionBalance]

        /// The default token Type of the Pool in which the related position is held
        access(all) let poolDefaultToken: Type

        /// The available balance of the Pool's default token Type
        access(all) let defaultTokenAvailableBalance: UFix64

        /// The current health of the related position
        access(all) let health: UFix128

        init(
            balances: [PositionBalance],
            poolDefaultToken: Type,
            defaultTokenAvailableBalance: UFix64,
            health: UFix128
        ) {
            self.balances = balances
            self.poolDefaultToken = poolDefaultToken
            self.defaultTokenAvailableBalance = defaultTokenAvailableBalance
            self.health = health
        }
    }

    /* --- PUBLIC METHODS ---- */

    /// Returns a health value computed from the provided effective collateral and debt values
    /// where health is a ratio of effective collateral over effective debt
    access(all) view fun healthComputation(effectiveCollateral: UFix128, effectiveDebt: UFix128): UFix128 {
        if effectiveDebt == 0.0 {
            // Handles X/0 (infinite) including 0/0 (safe empty position)
            return UFix128.max
        }

        if effectiveCollateral == 0.0 {
            // 0/Y where Y > 0 is 0 health (unsafe)
            return 0.0
        }

        if (effectiveDebt / effectiveCollateral) == 0.0 {
            // Negligible debt relative to collateral: treat as infinite
            return UFix128.max
        }

        return effectiveCollateral / effectiveDebt
    }

    // Converts a yearly interest rate to a per-second multiplication factor (stored in a UFix128 as a fixed point
    // number with 18 decimal places). The input to this function will be just the relative annual interest rate
    // (e.g. 0.05 for 5% interest), and the result will be the per-second multiplier (e.g. 1.000000000001).
    access(all) view fun perSecondInterestRate(yearlyRate: UFix128): UFix128 {
        let perSecondScaledValue = yearlyRate / 31_557_600.0 // 365.25 * 24.0 * 60.0 * 60.0
        assert(
            perSecondScaledValue < UFix128.max,
            message: "Per-second interest rate \(perSecondScaledValue) is too high"
        )
        return perSecondScaledValue + 1.0
    }

    /// Returns the compounded interest index reflecting the passage of time
    /// The result is: newIndex = oldIndex * perSecondRate ^ seconds
    access(all) view fun compoundInterestIndex(
        oldIndex: UFix128,
        perSecondRate: UFix128,
        elapsedSeconds: UFix64
    ): UFix128 {
        // Exponentiation by squaring on UFix128 for performance and precision
        let pow = FlowCreditMarketMath.powUFix128(perSecondRate, elapsedSeconds)
        return oldIndex * pow
    }

    /// Transforms the provided `scaledBalance` to a true balance (or actual balance)
    /// where the true balance is the scaledBalance + accrued interest
    /// and the scaled balance is the amount a borrower has actually interacted with (via deposits or withdrawals)
    access(all) view fun scaledBalanceToTrueBalance(
        _ scaled: UFix128,
        interestIndex: UFix128
    ): UFix128 {
        return scaled * interestIndex
    }

    /// Transforms the provided `trueBalance` to a scaled balance
    /// where the scaled balance is the amount a borrower has actually interacted with (via deposits or withdrawals)
    /// and the true balance is the amount with respect to accrued interest
    access(all) view fun trueBalanceToScaledBalance(
        _ trueBalance: UFix128,
        interestIndex: UFix128
    ): UFix128 {
        return trueBalance / interestIndex
    }

    /* --- INTERNAL METHODS --- */

    /// Returns a reference to the contract account's MOET Minter resource
    access(self) view fun _borrowMOETMinter(): &MOET.Minter {
        return self.account.storage.borrow<&MOET.Minter>(from: MOET.AdminStoragePath)
            ?? panic("Could not borrow reference to internal MOET Minter resource")
    }

    init() {
        self.PoolStoragePath = StoragePath(identifier: "flowCreditMarketPool_\(self.account.address)")!
        self.PoolFactoryPath = StoragePath(identifier: "flowCreditMarketPoolFactory_\(self.account.address)")!
        self.PoolPublicPath = PublicPath(identifier: "flowCreditMarketPool_\(self.account.address)")!
        self.PoolCapStoragePath = StoragePath(identifier: "flowCreditMarketPoolCap_\(self.account.address)")!

        // save PoolFactory in storage
        self.account.storage.save(
            <-create PoolFactory(),
            to: self.PoolFactoryPath
        )
        let factory = self.account.storage.borrow<&PoolFactory>(from: self.PoolFactoryPath)!
    }
}
