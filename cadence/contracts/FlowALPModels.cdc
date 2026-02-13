import "FungibleToken"
import "DeFiActions"
import "MOET"
import "FlowALPMath"
import "FlowALPInterestRates"

access(all) contract FlowALPModels {

    /// EImplementation
    ///
    /// Entitlement for internal implementation operations that maintain the pool's state
    /// and process asynchronous updates. This entitlement grants access to low-level state
    /// management functions used by the protocol's internal mechanisms.
    ///
    /// This entitlement is used internally by the protocol to maintain state consistency
    /// and process queued operations. It should not be granted to external users.
    access(all) entitlement EImplementation

    /// PoolConfig defines the interface for pool-level configuration parameters.
    access(all) struct interface PoolConfig {

        // Getters

        access(all) view fun getPriceOracle(): {DeFiActions.PriceOracle}
        access(all) view fun getCollateralFactor(tokenType: Type): UFix64
        access(all) view fun getBorrowFactor(tokenType: Type): UFix64
        access(all) view fun getPositionsProcessedPerCallback(): UInt64
        access(all) view fun getLiquidationTargetHF(): UFix128
        access(all) view fun getWarmupSec(): UInt64
        access(all) view fun getLastUnpausedAt(): UInt64?
        access(all) view fun getDex(): {DeFiActions.SwapperProvider}
        access(all) view fun getDexOracleDeviationBps(): UInt16

        // Setters

        access(all) fun setPriceOracle(_ newOracle: {DeFiActions.PriceOracle}, defaultToken: Type)
        access(all) fun setCollateralFactor(tokenType: Type, factor: UFix64)
        access(all) fun setBorrowFactor(tokenType: Type, factor: UFix64)
        access(all) fun setPositionsProcessedPerCallback(_ count: UInt64)
        access(all) fun setLiquidationTargetHF(_ targetHF: UFix128)
        access(all) fun setWarmupSec(_ warmupSec: UInt64)
        access(all) fun setLastUnpausedAt(_ time: UInt64?)
        access(all) fun setDex(_ dex: {DeFiActions.SwapperProvider})
        access(all) fun setDexOracleDeviationBps(_ bps: UInt16)
    }

    /// PoolConfigImpl is the concrete implementation of PoolConfig.
    access(all) struct PoolConfigImpl: PoolConfig {

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

        /// The count of positions to update per asynchronous update
        access(self) var positionsProcessedPerCallback: UInt64

        /// The target health factor when liquidating a position, which limits how much collateral can be liquidated.
        /// After a liquidation, the position's health factor must be less than or equal to this target value.
        access(self) var liquidationTargetHF: UFix128

        /// Period (s) following unpause in which liquidations are still not allowed
        access(self) var warmupSec: UInt64
        /// Time this pool most recently was unpaused
        access(self) var lastUnpausedAt: UInt64?

        /// A trusted DEX (or set of DEXes) used by FlowALPv1 as a pricing oracle and trading counterparty for liquidations.
        /// The SwapperProvider implementation MUST return a Swapper for all possible (ordered) pairs of supported tokens.
        /// If [X1, X2, ..., Xn] is the set of supported tokens, then the SwapperProvider must return a Swapper for all pairs:
        ///   (Xi, Xj) where i∈[1,n], j∈[1,n], i≠j
        ///
        /// FlowALPv1 does not attempt to construct multi-part paths (using multiple Swappers) or compare prices across Swappers.
        /// It relies directly on the Swapper's returned by the configured SwapperProvider.
        access(self) var dex: {DeFiActions.SwapperProvider}

        /// Max allowed deviation in basis points between DEX-implied price and oracle price.
        access(self) var dexOracleDeviationBps: UInt16

        init(
            priceOracle: {DeFiActions.PriceOracle},
            collateralFactor: {Type: UFix64},
            borrowFactor: {Type: UFix64},
            positionsProcessedPerCallback: UInt64,
            liquidationTargetHF: UFix128,
            warmupSec: UInt64,
            lastUnpausedAt: UInt64?,
            dex: {DeFiActions.SwapperProvider},
            dexOracleDeviationBps: UInt16,
        ) {
            self.priceOracle = priceOracle
            self.collateralFactor = collateralFactor
            self.borrowFactor = borrowFactor
            self.positionsProcessedPerCallback = positionsProcessedPerCallback
            self.liquidationTargetHF = liquidationTargetHF
            self.warmupSec = warmupSec
            self.lastUnpausedAt = lastUnpausedAt
            self.dex = dex
            self.dexOracleDeviationBps = dexOracleDeviationBps
        }

        // Getters

        access(all) view fun getPriceOracle(): {DeFiActions.PriceOracle} {
            return self.priceOracle
        }

        access(all) view fun getCollateralFactor(tokenType: Type): UFix64 {
            return self.collateralFactor[tokenType]!
        }

        access(all) view fun getBorrowFactor(tokenType: Type): UFix64 {
            return self.borrowFactor[tokenType]!
        }

        access(all) view fun getPositionsProcessedPerCallback(): UInt64 {
            return self.positionsProcessedPerCallback
        }

        access(all) view fun getLiquidationTargetHF(): UFix128 {
            return self.liquidationTargetHF
        }

        access(all) view fun getWarmupSec(): UInt64 {
            return self.warmupSec
        }

        access(all) view fun getLastUnpausedAt(): UInt64? {
            return self.lastUnpausedAt
        }

        access(all) view fun getDex(): {DeFiActions.SwapperProvider} {
            return self.dex
        }

        access(all) view fun getDexOracleDeviationBps(): UInt16 {
            return self.dexOracleDeviationBps
        }

        // Setters

        access(all) fun setPriceOracle(_ newOracle: {DeFiActions.PriceOracle}, defaultToken: Type) {
            pre {
                newOracle.unitOfAccount() == defaultToken:
                    "Price oracle must return prices in terms of the pool's default token"
            }
            self.priceOracle = newOracle
        }

        access(all) fun setCollateralFactor(tokenType: Type, factor: UFix64) {
            pre {
                factor > 0.0 && factor <= 1.0:
                    "Collateral factor must be between 0 and 1"
            }
            self.collateralFactor[tokenType] = factor
        }

        access(all) fun setBorrowFactor(tokenType: Type, factor: UFix64) {
            pre {
                factor > 0.0 && factor <= 1.0:
                    "Borrow factor must be between 0 and 1"
            }
            self.borrowFactor[tokenType] = factor
        }

        access(all) fun setPositionsProcessedPerCallback(_ count: UInt64) {
            self.positionsProcessedPerCallback = count
        }

        access(all) fun setLiquidationTargetHF(_ targetHF: UFix128) {
            pre {
                targetHF > 1.0:
                    "targetHF must be > 1.0"
            }
            self.liquidationTargetHF = targetHF
        }

        access(all) fun setWarmupSec(_ warmupSec: UInt64) {
            self.warmupSec = warmupSec
        }

        access(all) fun setLastUnpausedAt(_ time: UInt64?) {
            self.lastUnpausedAt = time
        }

        access(all) fun setDex(_ dex: {DeFiActions.SwapperProvider}) {
            self.dex = dex
        }

        access(all) fun setDexOracleDeviationBps(_ bps: UInt16) {
            self.dexOracleDeviationBps = bps
        }
    }

    /* --- EVENTS --- */

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

    /* --- TOKEN STATE --- */

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
        /// Interest indices are 18-decimal fixed-point values (see FlowALPMath) and are stored as UFix128
        /// to maintain precision when converting between scaled and true balances and when compounding.
        access(EImplementation) var creditInterestIndex: UFix128

        /// The index of the debit interest for the related token.
        ///
        /// Interest indices are 18-decimal fixed-point values (see FlowALPMath) and are stored as UFix128
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
        access(EImplementation) var interestCurve: {FlowALPInterestRates.InterestCurve}

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

        /// The minimum balance size for the related token T per position.
        /// This minimum balance is denominated in units of token T.
        /// Let this minimum balance be M. Then each position must have either:
        /// - A balance of 0
        /// - A credit balance greater than or equal to M
        /// - A debit balance greater than or equal to M
        access(EImplementation) var minimumTokenBalancePerPosition: UFix64

        init(
            tokenType: Type,
            interestCurve: {FlowALPInterestRates.InterestCurve},
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
            self.minimumTokenBalancePerPosition = 1.0
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
        /// Argument expressed as tokens per hour
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

        /// Sets the minimum token balance per position for this token state
        access(EImplementation) fun setMinimumTokenBalancePerPosition(_ minimum: UFix64) {
            self.minimumTokenBalancePerPosition = minimum
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
        access(EImplementation) fun setInterestCurve(_ curve: {FlowALPInterestRates.InterestCurve}) {
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

        // Updates the credit and debit interest index for this token, accounting for time since the last update.
        access(EImplementation) fun updateInterestIndices() {
            let currentTime = getCurrentBlock().timestamp
            let dt = currentTime - self.lastUpdate

            // No time elapsed or already at cap → nothing to do
            if dt <= 0.0 {
                return
            }

            // Update interest indices (dt > 0 ensures sensible compounding)
            self.creditInterestIndex = FlowALPMath.compoundInterestIndex(
                oldIndex: self.creditInterestIndex,
                perSecondRate: self.currentCreditRate,
                elapsedSeconds: dt
            )
            self.debitInterestIndex = FlowALPMath.compoundInterestIndex(
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
            // 1. FixedCurve: simple spread model (creditRate = debitRate * (1 - protocolFeeRate))
            //    Used for stable assets like MOET where rates are governance-controlled
            // 2. KinkCurve (and others): reserve factor model
            //    Insurance and stability are percentages of interest income, not a fixed spread
            if self.interestCurve.getType() == Type<FlowALPInterestRates.FixedCurve>() {
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

            self.currentCreditRate = FlowALPMath.perSecondInterestRate(yearlyRate: creditRate)
            self.currentDebitRate = FlowALPMath.perSecondInterestRate(yearlyRate: debitRate)
        }

        /// Collects insurance by withdrawing from reserves and swapping to MOET.
        /// The insurance amount is calculated based on the insurance rate applied to the total debit balance over the time elapsed.
        /// This should be called periodically (e.g., when updateInterestRates is called) to accumulate the insurance fund.
        /// CAUTION: This function will panic if no insuranceSwapper is provided.
        ///
        /// @param reserveVault: The reserve vault for this token type to withdraw insurance from
        /// @param oraclePrice: The current price for this token according to the Oracle, denominated in $
        /// @param maxDeviationBps: The max deviation between oracle/dex prices (see Pool.dexOracleDeviationBps)
        /// @return: A MOET vault containing the collected insurance funds, or nil if no collection occurred
        access(EImplementation) fun collectInsurance(
            reserveVault: auth(FungibleToken.Withdraw) &{FungibleToken.Vault},
            oraclePrice: UFix64,
            maxDeviationBps: UInt16
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
            let debitIncome = self.totalDebitBalance * (FlowALPMath.powUFix128(self.currentDebitRate, timeElapsed) - 1.0)
            let insuranceAmount = debitIncome * UFix128(self.insuranceRate)
            let insuranceAmountUFix64 = FlowALPMath.toUFix64RoundDown(insuranceAmount)

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
            let dexPrice = quote.outAmount / quote.inAmount
            assert(
                FlowALPMath.dexOraclePriceDeviationInRange(dexPrice: dexPrice, oraclePrice: oraclePrice, maxDeviationBps: maxDeviationBps),
                message: "DEX/oracle price deviation too large. Dex price: \(dexPrice), Oracle price: \(oraclePrice)")
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
            let interestIncome = self.totalDebitBalance * (FlowALPMath.powUFix128(self.currentDebitRate, timeElapsed) - 1.0)
            let stabilityAmount = interestIncome * stabilityFeeRate
            let stabilityAmountUFix64 = FlowALPMath.toUFix64RoundDown(stabilityAmount)

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

    /* --- POOL STATE --- */

    /// PoolState defines the interface for pool-level state fields.
    /// Pool references its state via this interface to allow future upgrades.
    access(all) resource interface PoolState {

        /// Enable or disable verbose contract logging for debugging.
        access(EImplementation) var debugLogging: Bool

        /// Global state for tracking each token
        access(EImplementation) var globalLedger: {Type: TokenState}

        /// The actual reserves of each token
        access(EImplementation) var reserves: @{Type: {FungibleToken.Vault}}

        /// The insurance fund vault storing MOET tokens collected from insurance rates
        access(EImplementation) var insuranceFund: @MOET.Vault

        /// Auto-incrementing position identifier counter
        access(EImplementation) var nextPositionID: UInt64

        /// The default token type used as the "unit of account" for the pool.
        access(all) let defaultToken: Type

        /// The stability fund vaults storing tokens collected from stability fee rates.
        access(EImplementation) var stabilityFunds: @{Type: {FungibleToken.Vault}}

        /// Position update queue to be processed as an asynchronous update
        access(EImplementation) var positionsNeedingUpdates: [UInt64]

        /// Reentrancy guards keyed by position id.
        access(EImplementation) var positionLock: {UInt64: Bool}

        /// Whether the pool is currently paused
        access(EImplementation) var paused: Bool

        access(EImplementation) fun incrementNextPositionID()
        access(EImplementation) fun setPaused(_ paused: Bool)
        access(EImplementation) fun setDebugLogging(_ enabled: Bool)
        access(EImplementation) fun setPositionsNeedingUpdates(_ positions: [UInt64])
    }

    /// PoolStateImpl is the concrete implementation of PoolState.
    /// This extraction enables future upgrades and testing of state management in isolation.
    access(all) resource PoolStateImpl: PoolState {

        /// Enable or disable verbose contract logging for debugging.
        access(EImplementation) var debugLogging: Bool

        /// Global state for tracking each token
        access(EImplementation) var globalLedger: {Type: TokenState}

        /// The actual reserves of each token
        access(EImplementation) var reserves: @{Type: {FungibleToken.Vault}}

        /// The insurance fund vault storing MOET tokens collected from insurance rates
        access(EImplementation) var insuranceFund: @MOET.Vault

        /// Auto-incrementing position identifier counter
        access(EImplementation) var nextPositionID: UInt64

        /// The default token type used as the "unit of account" for the pool.
        access(all) let defaultToken: Type

        /// The stability fund vaults storing tokens collected from stability fee rates.
        access(EImplementation) var stabilityFunds: @{Type: {FungibleToken.Vault}}

        /// Position update queue to be processed as an asynchronous update
        access(EImplementation) var positionsNeedingUpdates: [UInt64]

        /// Reentrancy guards keyed by position id.
        access(EImplementation) var positionLock: {UInt64: Bool}

        /// Whether the pool is currently paused
        access(EImplementation) var paused: Bool

        init(
            debugLogging: Bool,
            globalLedger: {Type: TokenState},
            reserves: @{Type: {FungibleToken.Vault}},
            insuranceFund: @MOET.Vault,
            nextPositionID: UInt64,
            defaultToken: Type,
            stabilityFunds: @{Type: {FungibleToken.Vault}},
            positionsNeedingUpdates: [UInt64],
            positionLock: {UInt64: Bool},
            paused: Bool
        ) {
            self.debugLogging = debugLogging
            self.globalLedger = globalLedger
            self.reserves <- reserves
            self.insuranceFund <- insuranceFund
            self.nextPositionID = nextPositionID
            self.defaultToken = defaultToken
            self.stabilityFunds <- stabilityFunds
            self.positionsNeedingUpdates = positionsNeedingUpdates
            self.positionLock = positionLock
            self.paused = paused
        }

        access(EImplementation) fun incrementNextPositionID() {
            self.nextPositionID = self.nextPositionID + 1
        }

        access(EImplementation) fun setPaused(_ paused: Bool) {
            self.paused = paused
        }

        access(EImplementation) fun setDebugLogging(_ enabled: Bool) {
            self.debugLogging = enabled
        }

        access(EImplementation) fun setPositionsNeedingUpdates(_ positions: [UInt64]) {
            self.positionsNeedingUpdates = positions
        }
    }

    /// Factory function to create a new PoolStateImpl resource.
    /// Required because Cadence resources can only be created within their containing contract.
    access(all) fun createPoolState(
        debugLogging: Bool,
        globalLedger: {Type: TokenState},
        reserves: @{Type: {FungibleToken.Vault}},
        insuranceFund: @MOET.Vault,
        nextPositionID: UInt64,
        defaultToken: Type,
        stabilityFunds: @{Type: {FungibleToken.Vault}},
        positionsNeedingUpdates: [UInt64],
        positionLock: {UInt64: Bool},
        paused: Bool
    ): @{PoolState} {
        return <- create PoolStateImpl(
            debugLogging: debugLogging,
            globalLedger: globalLedger,
            reserves: <-reserves,
            insuranceFund: <-insuranceFund,
            nextPositionID: nextPositionID,
            defaultToken: defaultToken,
            stabilityFunds: <-stabilityFunds,
            positionsNeedingUpdates: positionsNeedingUpdates,
            positionLock: positionLock,
            paused: paused
        )
    }
}
