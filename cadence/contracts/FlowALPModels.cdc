import "FungibleToken"
import "DeFiActions"
import "DeFiActionsUtils"
import "MOET"
import "FlowALPMath"
import "FlowALPInterestRates"
import "FlowALPEvents"

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

    /// BalanceDirection
    ///
    /// The direction of a given balance
    access(all) enum BalanceDirection: UInt8 {

        /// Denotes that a balance that is withdrawable from the protocol
        access(all) case Credit

        /// Denotes that a balance that is due to the protocol
        access(all) case Debit
    }

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
        access(all) fun recordDeposit(amount: UFix128, tokenState: &{TokenState}) {
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

                    let scaledDeposit = FlowALPMath.trueBalanceToScaledBalance(
                        amount,
                        interestIndex: tokenState.getCreditInterestIndex()
                    )

                    self.scaledBalance = self.scaledBalance + scaledDeposit

                    // Increase the total credit balance for the token
                    tokenState.increaseCreditBalance(by: amount)

                case BalanceDirection.Debit:
                    // When depositing into a debit position, we first need to compute the true balance
                    // to see if this deposit will flip the position from debit to credit.

                    let trueBalance = FlowALPMath.scaledBalanceToTrueBalance(
                        self.scaledBalance,
                        interestIndex: tokenState.getDebitInterestIndex()
                    )

                    // Harmonize comparison with withdrawal: treat an exact match as "does not flip to credit"
                    if trueBalance >= amount {
                        // The deposit isn't big enough to clear the debt,
                        // so we just decrement the debt.
                        let updatedBalance = trueBalance - amount

                        self.scaledBalance = FlowALPMath.trueBalanceToScaledBalance(
                            updatedBalance,
                            interestIndex: tokenState.getDebitInterestIndex()
                        )

                        // Decrease the total debit balance for the token
                        tokenState.decreaseDebitBalance(by: amount)

                    } else {
                        // The deposit is enough to clear the debt,
                        // so we switch to a credit position.
                        let updatedBalance = amount - trueBalance

                        self.direction = BalanceDirection.Credit
                        self.scaledBalance = FlowALPMath.trueBalanceToScaledBalance(
                            updatedBalance,
                            interestIndex: tokenState.getCreditInterestIndex()
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
        access(all) fun recordWithdrawal(amount: UFix128, tokenState: &{TokenState}) {
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

                    let scaledWithdrawal = FlowALPMath.trueBalanceToScaledBalance(
                        amount,
                        interestIndex: tokenState.getDebitInterestIndex()
                    )

                    self.scaledBalance = self.scaledBalance + scaledWithdrawal

                    // Increase the total debit balance for the token
                    tokenState.increaseDebitBalance(by: amount)

                case BalanceDirection.Credit:
                    // When withdrawing from a credit position,
                    // we first need to compute the true balance
                    // to see if this withdrawal will flip the position from credit to debit.
                    let trueBalance = FlowALPMath.scaledBalanceToTrueBalance(
                        self.scaledBalance,
                        interestIndex: tokenState.getCreditInterestIndex()
                    )

                    if trueBalance >= amount {
                        // The withdrawal isn't big enough to push the position into debt,
                        // so we just decrement the credit balance.
                        let updatedBalance = trueBalance - amount

                        self.scaledBalance = FlowALPMath.trueBalanceToScaledBalance(
                            updatedBalance,
                            interestIndex: tokenState.getCreditInterestIndex()
                        )

                        // Decrease the total credit balance for the token
                        tokenState.decreaseCreditBalance(by: amount)
                    } else {
                        // The withdrawal is enough to push the position into debt,
                        // so we switch to a debit position.
                        let updatedBalance = amount - trueBalance

                        self.direction = BalanceDirection.Debit
                        self.scaledBalance = FlowALPMath.trueBalanceToScaledBalance(
                            updatedBalance,
                            interestIndex: tokenState.getDebitInterestIndex()
                        )

                        // Decrease the credit balance AND increase the debit balance
                        tokenState.decreaseCreditBalance(by: trueBalance)
                        tokenState.increaseDebitBalance(by: updatedBalance)
                    }
            }
        }
    }

    /// Risk parameters for a token used in effective collateral/debt computations.
    /// The collateral and borrow factors are fractional values which represent a discount to the "true/market" value of the token.
    /// The size of this discount indicates a subjective assessment of risk for the token.
    /// The difference between the effective value and "true" value represents the safety buffer available to prevent loss.
    /// - collateralFactor: the factor used to derive effective collateral
    /// - borrowFactor: the factor used to derive effective debt
    access(all) struct interface RiskParams {
        /// The factor (Fc) used to determine effective collateral, in the range [0, 1]
        /// See FlowALPMath.effectiveCollateral for additional detail.
        access(all) view fun getCollateralFactor(): UFix128
        /// The factor (Fd) used to determine effective debt, in the range [0, 1]
        /// See FlowALPMath.effectiveDebt for additional detail.
        access(all) view fun getBorrowFactor(): UFix128
    }

    /// RiskParamsImplv1 is the concrete implementation of RiskParams.
    access(all) struct RiskParamsImplv1: RiskParams {
        access(self) let collateralFactor: UFix128
        access(self) let borrowFactor: UFix128

        init(
            collateralFactor: UFix128,
            borrowFactor: UFix128,
        ) {
            pre {
                collateralFactor <= 1.0: "collateral factor must be <=1"
                borrowFactor <= 1.0: "borrow factor must be <=1"
            }
            self.collateralFactor = collateralFactor
            self.borrowFactor = borrowFactor
        }

        access(all) view fun getCollateralFactor(): UFix128 {
            return self.collateralFactor
        }

        access(all) view fun getBorrowFactor(): UFix128 {
            return self.borrowFactor
        }
    }

    /// Immutable snapshot of token-level data required for pure math operations
    access(all) struct interface TokenSnapshot {
        access(all) view fun getPrice(): UFix128
        access(all) view fun getCreditIndex(): UFix128
        access(all) view fun getDebitIndex(): UFix128
        access(all) view fun getRisk(): {RiskParams}
        /// Returns the effective debt (denominated in $) for the given debit balance of this snapshot's token.
        /// See FlowALPMath.effectiveDebt for additional details.
        access(all) view fun effectiveDebt(debitBalance: UFix128): UFix128
        /// Returns the effective collateral (denominated in $) for the given credit balance of this snapshot's token.
        /// See FlowALPMath.effectiveCollateral for additional details.
        access(all) view fun effectiveCollateral(creditBalance: UFix128): UFix128
    }

    /// TokenSnapshotImplv1 is the concrete implementation of TokenSnapshot.
    access(all) struct TokenSnapshotImplv1: TokenSnapshot {
        access(self) let price: UFix128
        access(self) let creditIndex: UFix128
        access(self) let debitIndex: UFix128
        access(self) let risk: {RiskParams}

        init(
            price: UFix128,
            credit: UFix128,
            debit: UFix128,
            risk: {RiskParams}
        ) {
            self.price = price
            self.creditIndex = credit
            self.debitIndex = debit
            self.risk = risk
        }

        access(all) view fun getPrice(): UFix128 {
            return self.price
        }

        access(all) view fun getCreditIndex(): UFix128 {
            return self.creditIndex
        }

        access(all) view fun getDebitIndex(): UFix128 {
            return self.debitIndex
        }

        access(all) view fun getRisk(): {RiskParams} {
            return self.risk
        }

        /// Returns the effective debt (denominated in $) for the given debit balance of this snapshot's token.
        /// See FlowALPMath.effectiveDebt for additional details.
        access(all) view fun effectiveDebt(debitBalance: UFix128): UFix128 {
            return FlowALPMath.effectiveDebt(debit: debitBalance, price: self.price, borrowFactor: self.risk.getBorrowFactor())
        }

        /// Returns the effective collateral (denominated in $) for the given credit balance of this snapshot's token.
        /// See FlowALPMath.effectiveCollateral for additional details.
        access(all) view fun effectiveCollateral(creditBalance: UFix128): UFix128 {
            return FlowALPMath.effectiveCollateral(credit: creditBalance, price: self.price, collateralFactor: self.risk.getCollateralFactor())
        }
    }

    /// Copy-only representation of a position used by pure math (no storage refs)
    access(all) struct PositionView {
        /// Set of all non-zero balances in the position.
        /// If the position does not have a balance for a supported token, no entry for that token exists in this map.
        access(all) let balances: {Type: InternalBalance}
        /// Set of all token snapshots for which this position has a non-zero balance.
        /// If the position does not have a balance for a supported token, no entry for that token exists in this map.
        access(all) let snapshots: {Type: {TokenSnapshot}}
        access(all) let defaultToken: Type
        access(all) let minHealth: UFix128
        access(all) let maxHealth: UFix128

        init(
            balances: {Type: InternalBalance},
            snapshots: {Type: {TokenSnapshot}},
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
                        return FlowALPMath.scaledBalanceToTrueBalance(
                            balance.scaledBalance, interestIndex: tokenSnapshot.getDebitIndex())
                    case BalanceDirection.Credit:
                        return FlowALPMath.scaledBalanceToTrueBalance(
                            balance.scaledBalance, interestIndex: tokenSnapshot.getCreditIndex())
                    }
                    panic("unreachable")
                }
            }
            // If the token doesn't exist in the position, the balance is 0
            return 0.0
        }
    }

    /// Computes health = totalEffectiveCollateral / totalEffectiveDebt (∞ when debt == 0)
    access(all) view fun healthFactor(view: PositionView): UFix128 {
        var effectiveCollateralTotal: UFix128 = 0.0
        var effectiveDebtTotal: UFix128 = 0.0

        for tokenType in view.balances.keys {
            let balance = view.balances[tokenType]!
            let snap = view.snapshots[tokenType]!

            switch balance.direction {
                case BalanceDirection.Credit:
                    let trueBalance = FlowALPMath.scaledBalanceToTrueBalance(
                        balance.scaledBalance,
                        interestIndex: snap.getCreditIndex()
                    )
                    effectiveCollateralTotal = effectiveCollateralTotal
                        + snap.effectiveCollateral(creditBalance: trueBalance)

                case BalanceDirection.Debit:
                    let trueBalance = FlowALPMath.scaledBalanceToTrueBalance(
                        balance.scaledBalance,
                        interestIndex: snap.getDebitIndex()
                    )
                    effectiveDebtTotal = effectiveDebtTotal
                        + snap.effectiveDebt(debitBalance: trueBalance)
            }
        }
        return FlowALPMath.healthComputation(
            effectiveCollateral: effectiveCollateralTotal,
            effectiveDebt: effectiveDebtTotal
        )
    }

    /// BalanceSheet
    ///
    /// A struct containing a position's overview in terms of its effective collateral and debt
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
            self.health = FlowALPMath.healthComputation(
                effectiveCollateral: effectiveCollateral,
                effectiveDebt: effectiveDebt
            )
        }
    }

    access(all) struct PauseParamsView {
        access(all) let paused: Bool
        access(all) let warmupSec: UInt64
        access(all) let lastUnpausedAt: UInt64?

        init(
            paused: Bool,
            warmupSec: UInt64,
            lastUnpausedAt: UInt64?,
        ) {
            self.paused = paused
            self.warmupSec = warmupSec
            self.lastUnpausedAt = lastUnpausedAt
        }
    }

    /// Liquidation parameters view (global)
    access(all) struct LiquidationParamsView {
        access(all) let targetHF: UFix128
        access(all) let triggerHF: UFix128

        init(
            targetHF: UFix128,
            triggerHF: UFix128,
        ) {
            self.targetHF = targetHF
            self.triggerHF = triggerHF
        }
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
        access(all) view fun isPaused(): Bool
        access(all) view fun isDebugLogging(): Bool
        access(all) view fun getSupportedTokens(): [Type]
        access(all) view fun isTokenSupported(tokenType: Type): Bool
        access(all) fun getSwapperForLiquidation(seizeType: Type, debtType: Type): {DeFiActions.Swapper}

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
        access(all) fun setPaused(_ paused: Bool)
        access(all) fun setDebugLogging(_ enabled: Bool)
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

        /// A trusted DEX (or set of DEXes) used by FlowALPv0 as a pricing oracle and trading counterparty for liquidations.
        /// The SwapperProvider implementation MUST return a Swapper for all possible (ordered) pairs of supported tokens.
        /// If [X1, X2, ..., Xn] is the set of supported tokens, then the SwapperProvider must return a Swapper for all pairs:
        ///   (Xi, Xj) where i∈[1,n], j∈[1,n], i≠j
        ///
        /// FlowALPv0 does not attempt to construct multi-part paths (using multiple Swappers) or compare prices across Swappers.
        /// It relies directly on the Swapper's returned by the configured SwapperProvider.
        access(self) var dex: {DeFiActions.SwapperProvider}

        /// Max allowed deviation in basis points between DEX-implied price and oracle price.
        access(self) var dexOracleDeviationBps: UInt16

        /// Whether the pool is currently paused
        access(self) var paused: Bool

        /// Enable or disable verbose contract logging for debugging.
        access(self) var debugLogging: Bool

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
            paused: Bool,
            debugLogging: Bool,
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
            self.paused = paused
            self.debugLogging = debugLogging
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

        access(all) view fun isPaused(): Bool {
            return self.paused
        }

        access(all) view fun isDebugLogging(): Bool {
            return self.debugLogging
        }

        access(all) view fun getSupportedTokens(): [Type] {
            return self.collateralFactor.keys
        }

        access(all) view fun isTokenSupported(tokenType: Type): Bool {
            return self.collateralFactor[tokenType] != nil
        }

        access(all) fun getSwapperForLiquidation(seizeType: Type, debtType: Type): {DeFiActions.Swapper} {
            return self.dex.getSwapper(inType: seizeType, outType: debtType)
                ?? panic("No DEX swapper configured for liquidation pair: ".concat(seizeType.identifier).concat(" -> ").concat(debtType.identifier))
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

        access(all) fun setPaused(_ paused: Bool) {
            self.paused = paused
        }

        access(all) fun setDebugLogging(_ enabled: Bool) {
            self.debugLogging = enabled
        }
    }

    /* --- TOKEN STATE --- */

    /// TokenState
    ///
    /// The TokenState interface defines the contract for accessing and mutating state
    /// related to a single token Type within the Pool.
    /// All state is accessed via getter/setter functions (no field declarations),
    /// enabling future implementation upgrades (e.g. TokenStateImplv2).
    access(all) struct interface TokenState {

        // --- Getters ---

        /// The token type this state tracks
        access(all) view fun getTokenType(): Type

        /// The timestamp at which the TokenState was last updated
        access(all) view fun getLastUpdate(): UFix64

        /// The total credit balance for this token, in a specific Pool.
        /// The total credit balance is the sum of balances of all positions with a credit balance (ie. they have lent this token).
        /// In other words, it is the the sum of net deposits among positions which are net creditors in this token.
        access(all) view fun getTotalCreditBalance(): UFix128

        /// The total debit balance for this token, in a specific Pool.
        /// The total debit balance is the sum of balances of all positions with a debit balance (ie. they have borrowed this token).
        /// In other words, it is the the sum of net withdrawals among positions which are net debtors in this token.
        access(all) view fun getTotalDebitBalance(): UFix128

        /// The index of the credit interest for the related token.
        ///
        /// Interest indices are 18-decimal fixed-point values (see FlowALPMath) and are stored as UFix128
        /// to maintain precision when converting between scaled and true balances and when compounding.
        access(all) view fun getCreditInterestIndex(): UFix128

        /// The index of the debit interest for the related token.
        ///
        /// Interest indices are 18-decimal fixed-point values (see FlowALPMath) and are stored as UFix128
        /// to maintain precision when converting between scaled and true balances and when compounding.
        access(all) view fun getDebitInterestIndex(): UFix128

        /// The per-second interest rate for credit of the associated token.
        ///
        /// For example, if the per-second rate is 1%, this value is 0.01.
        /// Stored as UFix128 to match index precision and avoid cumulative rounding during compounding.
        access(all) view fun getCurrentCreditRate(): UFix128

        /// The per-second interest rate for debit of the associated token.
        ///
        /// For example, if the per-second rate is 1%, this value is 0.01.
        /// Stored as UFix128 for consistency with indices/rates math.
        access(all) view fun getCurrentDebitRate(): UFix128

        /// The interest curve implementation used to calculate interest rate
        access(all) view fun getInterestCurve(): {FlowALPInterestRates.InterestCurve}

        /// The annual insurance rate applied to total debit when computing credit interest (default 0.1%)
        access(all) view fun getInsuranceRate(): UFix64

        /// Timestamp of the last insurance collection for this token.
        access(all) view fun getLastInsuranceCollectionTime(): UFix64

        /// Swapper used to convert this token to MOET for insurance collection.
        access(all) view fun getInsuranceSwapper(): {DeFiActions.Swapper}?

        /// The stability fee rate to calculate stability (default 0.05, 5%).
        access(all) view fun getStabilityFeeRate(): UFix64

        /// Timestamp of the last stability collection for this token.
        access(all) view fun getLastStabilityFeeCollectionTime(): UFix64

        /// Per-position limit fraction of capacity (default 0.05 i.e., 5%)
        access(all) view fun getDepositLimitFraction(): UFix64

        /// The rate at which depositCapacity can increase over time. This is a tokens per hour rate,
        /// and should be applied to the depositCapacityCap once an hour.
        access(all) view fun getDepositRate(): UFix64

        /// The timestamp of the last deposit capacity update
        access(all) view fun getLastDepositCapacityUpdate(): UFix64

        /// The limit on deposits of the related token
        access(all) view fun getDepositCapacity(): UFix64

        /// The upper bound on total deposits of the related token,
        /// limiting how much depositCapacity can reach
        access(all) view fun getDepositCapacityCap(): UFix64

        /// Returns the deposit usage for a specific position ID.
        /// Returns 0.0 if no usage has been recorded for the position.
        access(all) view fun getDepositUsageForPosition(_ pid: UInt64): UFix64

        /// The minimum balance size for the related token T per position.
        /// This minimum balance is denominated in units of token T.
        /// Let this minimum balance be M. Then each position must have either:
        /// - A balance of 0
        /// - A credit balance greater than or equal to M
        /// - A debit balance greater than or equal to M
        access(all) view fun getMinimumTokenBalancePerPosition(): UFix64

        // --- Setters ---

        /// Sets the insurance rate for this token state
        access(all) fun setInsuranceRate(_ rate: UFix64)

        /// Sets the last insurance collection timestamp
        access(all) fun setLastInsuranceCollectionTime(_ lastInsuranceCollectionTime: UFix64)

        /// Sets the swapper used for insurance collection (must swap from this token type to MOET)
        access(all) fun setInsuranceSwapper(_ swapper: {DeFiActions.Swapper}?)

        /// Sets the per-deposit limit fraction for this token state
        access(all) fun setDepositLimitFraction(_ frac: UFix64)

        /// Sets the deposit rate for this token state after settling the old rate
        /// Argument expressed as tokens per hour
        access(all) fun setDepositRate(_ hourlyRate: UFix64)

        /// Sets the deposit capacity cap for this token state
        access(all) fun setDepositCapacityCap(_ cap: UFix64)

        /// Sets the minimum token balance per position for this token state
        access(all) fun setMinimumTokenBalancePerPosition(_ minimum: UFix64)

        /// Sets the stability fee rate for this token state.
        access(all) fun setStabilityFeeRate(_ rate: UFix64)

        /// Sets the last stability fee collection timestamp for this token state.
        access(all) fun setLastStabilityFeeCollectionTime(_ lastStabilityFeeCollectionTime: UFix64)

        /// Sets deposit capacity (used for time-based regeneration)
        access(all) fun setDepositCapacity(_ capacity: UFix64)

        /// Sets the interest curve for this token state
        /// After updating the curve, also update the interest rates to reflect the new curve
        access(all) fun setInterestCurve(_ curve: {FlowALPInterestRates.InterestCurve})

        // --- Operational Methods ---

        /// Calculates the per-user deposit limit cap based on depositLimitFraction * depositCapacityCap
        access(all) view fun getUserDepositLimitCap(): UFix64

        /// Decreases deposit capacity by the specified amount and tracks per-user deposit usage
        /// (used when deposits are made)
        access(all) fun consumeDepositCapacity(_ amount: UFix64, pid: UInt64)

        /// Returns the per-deposit limit based on depositCapacity * depositLimitFraction
        /// Rationale: cap per-deposit size to a fraction of the time-based
        /// depositCapacity so a single large deposit cannot monopolize capacity.
        /// Excess is queued and drained in chunks (see asyncUpdatePosition),
        /// enabling fair throughput across many deposits in a block. The 5%
        /// fraction is conservative and can be tuned by protocol parameters.
        access(all) view fun depositLimit(): UFix64

        /// Updates interest indices and regenerates deposit capacity for elapsed time
        access(all) fun updateForTimeChange()

        /// Called after any action that changes utilization (deposits, withdrawals, borrows, repays).
        /// Recalculates interest rates based on the new credit/debit balance ratio.
        access(all) fun updateForUtilizationChange()

        /// Recalculates interest rates based on the current credit/debit balance ratio and interest curve
        access(all) fun updateInterestRates()

        /// Updates the credit and debit interest index for this token, accounting for time since the last update.
        access(all) fun updateInterestIndices()

        /// Regenerates deposit capacity over time based on depositRate
        /// When capacity regenerates, all user deposit usage is reset for this token type
        access(all) fun regenerateDepositCapacity()

        /// Balance update helpers used by core accounting.
        /// All balance changes automatically trigger updateForUtilizationChange()
        /// which recalculates interest rates based on the new utilization ratio.
        /// This ensures rates always reflect the current state of the pool
        /// without requiring manual rate update calls.
        access(all) fun increaseCreditBalance(by amount: UFix128)
        access(all) fun decreaseCreditBalance(by amount: UFix128)
        access(all) fun increaseDebitBalance(by amount: UFix128)
        access(all) fun decreaseDebitBalance(by amount: UFix128)
    }

    /// TokenStateImplv1 is the concrete implementation of TokenState.
    /// Fields are private (access(self)) and accessed only via getter/setter functions.
    access(all) struct TokenStateImplv1: TokenState {

        access(self) var tokenType: Type
        access(self) var lastUpdate: UFix64
        access(self) var totalCreditBalance: UFix128
        access(self) var totalDebitBalance: UFix128
        access(self) var creditInterestIndex: UFix128
        access(self) var debitInterestIndex: UFix128
        access(self) var currentCreditRate: UFix128
        access(self) var currentDebitRate: UFix128
        access(self) var interestCurve: {FlowALPInterestRates.InterestCurve}
        access(self) var insuranceRate: UFix64
        access(self) var lastInsuranceCollectionTime: UFix64
        access(self) var insuranceSwapper: {DeFiActions.Swapper}?
        access(self) var stabilityFeeRate: UFix64
        access(self) var lastStabilityFeeCollectionTime: UFix64
        access(self) var depositLimitFraction: UFix64
        access(self) var depositRate: UFix64
        access(self) var lastDepositCapacityUpdate: UFix64
        access(self) var depositCapacity: UFix64
        access(self) var depositCapacityCap: UFix64
        access(self) var depositUsage: {UInt64: UFix64}
        access(self) var minimumTokenBalancePerPosition: UFix64

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

        // --- Getters ---

        access(all) view fun getTokenType(): Type {
            return self.tokenType
        }

        access(all) view fun getLastUpdate(): UFix64 {
            return self.lastUpdate
        }

        access(all) view fun getTotalCreditBalance(): UFix128 {
            return self.totalCreditBalance
        }

        access(all) view fun getTotalDebitBalance(): UFix128 {
            return self.totalDebitBalance
        }

        access(all) view fun getCreditInterestIndex(): UFix128 {
            return self.creditInterestIndex
        }

        access(all) view fun getDebitInterestIndex(): UFix128 {
            return self.debitInterestIndex
        }

        access(all) view fun getCurrentCreditRate(): UFix128 {
            return self.currentCreditRate
        }

        access(all) view fun getCurrentDebitRate(): UFix128 {
            return self.currentDebitRate
        }

        access(all) view fun getInterestCurve(): {FlowALPInterestRates.InterestCurve} {
            return self.interestCurve
        }

        access(all) view fun getInsuranceRate(): UFix64 {
            return self.insuranceRate
        }

        access(all) view fun getLastInsuranceCollectionTime(): UFix64 {
            return self.lastInsuranceCollectionTime
        }

        access(all) view fun getInsuranceSwapper(): {DeFiActions.Swapper}? {
            return self.insuranceSwapper
        }

        access(all) view fun getStabilityFeeRate(): UFix64 {
            return self.stabilityFeeRate
        }

        access(all) view fun getLastStabilityFeeCollectionTime(): UFix64 {
            return self.lastStabilityFeeCollectionTime
        }

        access(all) view fun getDepositLimitFraction(): UFix64 {
            return self.depositLimitFraction
        }

        access(all) view fun getDepositRate(): UFix64 {
            return self.depositRate
        }

        access(all) view fun getLastDepositCapacityUpdate(): UFix64 {
            return self.lastDepositCapacityUpdate
        }

        access(all) view fun getDepositCapacity(): UFix64 {
            return self.depositCapacity
        }

        access(all) view fun getDepositCapacityCap(): UFix64 {
            return self.depositCapacityCap
        }

        access(all) view fun getDepositUsageForPosition(_ pid: UInt64): UFix64 {
            return self.depositUsage[pid] ?? 0.0
        }

        access(all) view fun getMinimumTokenBalancePerPosition(): UFix64 {
            return self.minimumTokenBalancePerPosition
        }

        // --- Setters ---

        access(all) fun setInsuranceRate(_ rate: UFix64) {
            self.insuranceRate = rate
        }

        access(all) fun setLastInsuranceCollectionTime(_ lastInsuranceCollectionTime: UFix64) {
            self.lastInsuranceCollectionTime = lastInsuranceCollectionTime
        }

        access(all) fun setInsuranceSwapper(_ swapper: {DeFiActions.Swapper}?) {
            if let swapper = swapper {
                assert(swapper.inType() == self.tokenType, message: "Insurance swapper must accept \(self.tokenType.identifier), not \(swapper.inType().identifier)")
                assert(swapper.outType() == Type<@MOET.Vault>(), message: "Insurance swapper must output MOET")
            }
            self.insuranceSwapper = swapper
        }

        access(all) fun setDepositLimitFraction(_ frac: UFix64) {
            self.depositLimitFraction = frac
        }

        access(all) fun setDepositRate(_ hourlyRate: UFix64) {
            // settle using old rate if for some reason too much time has passed without regeneration
            self.regenerateDepositCapacity()
            self.depositRate = hourlyRate
        }

        access(all) fun setDepositCapacityCap(_ cap: UFix64) {
            self.depositCapacityCap = cap
            // If current capacity exceeds the new cap, clamp it to the cap
            if self.depositCapacity > cap {
                self.depositCapacity = cap
            }
            // Reset the last update timestamp to prevent regeneration based on old timestamp
            self.lastDepositCapacityUpdate = getCurrentBlock().timestamp
        }

        access(all) fun setMinimumTokenBalancePerPosition(_ minimum: UFix64) {
            self.minimumTokenBalancePerPosition = minimum
        }

        access(all) fun setStabilityFeeRate(_ rate: UFix64) {
            self.stabilityFeeRate = rate
        }

        access(all) fun setLastStabilityFeeCollectionTime(_ lastStabilityFeeCollectionTime: UFix64) {
            self.lastStabilityFeeCollectionTime = lastStabilityFeeCollectionTime
        }

        access(all) fun setDepositCapacity(_ capacity: UFix64) {
            self.depositCapacity = capacity
        }

        access(all) fun setInterestCurve(_ curve: {FlowALPInterestRates.InterestCurve}) {
            self.interestCurve = curve
            // Update rates immediately to reflect the new curve
            self.updateInterestRates()
        }

        // --- Operational Methods ---

        access(all) view fun getUserDepositLimitCap(): UFix64 {
            return self.depositLimitFraction * self.depositCapacityCap
        }

        access(all) fun consumeDepositCapacity(_ amount: UFix64, pid: UInt64) {
            assert(
                amount <= self.depositCapacity,
                message: "cannot consume more than available deposit capacity"
            )
            self.depositCapacity = self.depositCapacity - amount

            // Track per-user deposit usage for the accepted amount
            let currentUserUsage = self.depositUsage[pid] ?? 0.0
            self.depositUsage[pid] = currentUserUsage + amount

            FlowALPEvents.emitDepositCapacityConsumed(
                tokenType: self.tokenType,
                pid: pid,
                amount: amount,
                remainingCapacity: self.depositCapacity
            )
        }

        access(all) view fun depositLimit(): UFix64 {
            return self.depositCapacity * self.depositLimitFraction
        }

        access(all) fun updateForTimeChange() {
            self.updateInterestIndices()
            self.regenerateDepositCapacity()
        }

        access(all) fun updateForUtilizationChange() {
            self.updateInterestRates()
        }

        access(all) fun updateInterestRates() {
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

        access(all) fun updateInterestIndices() {
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

        access(all) fun regenerateDepositCapacity() {
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

                FlowALPEvents.emitDepositCapacityRegenerated(
                    tokenType: self.tokenType,
                    oldCapacityCap: oldCap,
                    newCapacityCap: newDepositCapacityCap
                )
            }
        }

        access(all) fun increaseCreditBalance(by amount: UFix128) {
            self.totalCreditBalance = self.totalCreditBalance + amount
            self.updateForUtilizationChange()
        }

        access(all) fun decreaseCreditBalance(by amount: UFix128) {
            if amount >= self.totalCreditBalance {
                self.totalCreditBalance = 0.0
            } else {
                self.totalCreditBalance = self.totalCreditBalance - amount
            }
            self.updateForUtilizationChange()
        }

        access(all) fun increaseDebitBalance(by amount: UFix128) {
            self.totalDebitBalance = self.totalDebitBalance + amount
            self.updateForUtilizationChange()
        }

        access(all) fun decreaseDebitBalance(by amount: UFix128) {
            if amount >= self.totalDebitBalance {
                self.totalDebitBalance = 0.0
            } else {
                self.totalDebitBalance = self.totalDebitBalance - amount
            }
            self.updateForUtilizationChange()
        }
    }

    /* --- POOL STATE --- */

    /// PoolState defines the interface for pool-level state fields.
    /// Pool references its state via this interface to allow future upgrades.
    /// All state is accessed via getter/setter functions (no field declarations).
    access(all) resource interface PoolState {

        // --- Global Ledger (TokenState per token type) ---
        access(EImplementation) fun borrowTokenState(_ type: Type): &{TokenState}?
        access(all) view fun getTokenState(_ type: Type): {TokenState}?
        access(EImplementation) fun setTokenState(_ type: Type, _ state: {TokenState})
        access(all) view fun getGlobalLedgerKeys(): [Type]

        // --- Reserves ---
        access(EImplementation) fun borrowOrCreateReserve(_ type: Type): auth(FungibleToken.Withdraw) &{FungibleToken.Vault}
        access(EImplementation) fun borrowReserve(_ type: Type): auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?
        access(all) view fun hasReserve(_ type: Type): Bool
        access(all) view fun getReserveBalance(_ type: Type): UFix64
        access(EImplementation) fun initReserve(_ type: Type, _ vault: @{FungibleToken.Vault})

        // --- Insurance Fund ---
        access(all) view fun getInsuranceFundBalance(): UFix64
        access(EImplementation) fun depositToInsuranceFund(from: @MOET.Vault)

        // --- Next Position ID ---
        access(all) view fun getNextPositionID(): UInt64
        access(EImplementation) fun incrementNextPositionID()

        // --- Default Token ---
        access(all) view fun getDefaultToken(): Type

        // --- Stability Funds ---
        access(EImplementation) fun borrowStabilityFund(_ type: Type): auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?
        access(all) view fun hasStabilityFund(_ type: Type): Bool
        access(all) view fun getStabilityFundBalance(_ type: Type): UFix64
        access(EImplementation) fun initStabilityFund(_ type: Type, _ vault: @{FungibleToken.Vault})

        // --- Position Update Queue ---
        access(all) view fun getPositionsNeedingUpdatesLength(): Int
        access(EImplementation) fun removeFirstPositionNeedingUpdate(): UInt64
        access(all) view fun positionsNeedingUpdatesContains(_ pid: UInt64): Bool
        access(EImplementation) fun appendPositionNeedingUpdate(_ pid: UInt64)
        access(EImplementation) fun setPositionsNeedingUpdates(_ positions: [UInt64])

        // --- Position Lock ---
        access(all) view fun isPositionLocked(_ pid: UInt64): Bool
        access(EImplementation) fun setPositionLock(_ pid: UInt64, _ locked: Bool)
        access(EImplementation) fun removePositionLock(_ pid: UInt64)
    }

    /// PoolStateImpl is the concrete implementation of PoolState.
    /// This extraction enables future upgrades and testing of state management in isolation.
    access(all) resource PoolStateImpl: PoolState {

        access(self) var globalLedger: {Type: {TokenState}}
        access(self) var reserves: @{Type: {FungibleToken.Vault}}
        access(self) var insuranceFund: @MOET.Vault
        access(self) var nextPositionID: UInt64
        access(self) let defaultToken: Type
        access(self) var stabilityFunds: @{Type: {FungibleToken.Vault}}
        access(self) var positionsNeedingUpdates: [UInt64]
        access(self) var positionLock: {UInt64: Bool}

        init(
            globalLedger: {Type: {TokenState}},
            reserves: @{Type: {FungibleToken.Vault}},
            insuranceFund: @MOET.Vault,
            nextPositionID: UInt64,
            defaultToken: Type,
            stabilityFunds: @{Type: {FungibleToken.Vault}},
            positionsNeedingUpdates: [UInt64],
            positionLock: {UInt64: Bool}
        ) {
            self.globalLedger = globalLedger
            self.reserves <- reserves
            self.insuranceFund <- insuranceFund
            self.nextPositionID = nextPositionID
            self.defaultToken = defaultToken
            self.stabilityFunds <- stabilityFunds
            self.positionsNeedingUpdates = positionsNeedingUpdates
            self.positionLock = positionLock
        }

        // --- Global Ledger ---

        access(EImplementation) fun borrowTokenState(_ type: Type): &{TokenState}? {
            return &self.globalLedger[type]
        }

        access(all) view fun getTokenState(_ type: Type): {TokenState}? {
            return self.globalLedger[type]
        }

        access(EImplementation) fun setTokenState(_ type: Type, _ state: {TokenState}) {
            self.globalLedger[type] = state
        }

        access(all) view fun getGlobalLedgerKeys(): [Type] {
            return self.globalLedger.keys
        }

        // --- Reserves ---

        access(EImplementation) fun borrowOrCreateReserve(_ type: Type): auth(FungibleToken.Withdraw) &{FungibleToken.Vault} {
            if self.reserves[type] == nil {
                self.reserves[type] <-! DeFiActionsUtils.getEmptyVault(type)
            }
            return (&self.reserves[type])!
        }

        access(EImplementation) fun borrowReserve(_ type: Type): auth(FungibleToken.Withdraw) &{FungibleToken.Vault}? {
            return &self.reserves[type]
        }

        access(all) view fun hasReserve(_ type: Type): Bool {
            return self.reserves[type] != nil
        }

        access(all) view fun getReserveBalance(_ type: Type): UFix64 {
            if let ref = &self.reserves[type] as &{FungibleToken.Vault}? {
                return ref.balance
            }
            return 0.0
        }

        access(EImplementation) fun initReserve(_ type: Type, _ vault: @{FungibleToken.Vault}) {
            self.reserves[type] <-! vault
        }

        // --- Insurance Fund ---

        access(all) view fun getInsuranceFundBalance(): UFix64 {
            return self.insuranceFund.balance
        }

        access(EImplementation) fun depositToInsuranceFund(from: @MOET.Vault) {
            self.insuranceFund.deposit(from: <-from)
        }

        // --- Next Position ID ---

        access(all) view fun getNextPositionID(): UInt64 {
            return self.nextPositionID
        }

        access(EImplementation) fun incrementNextPositionID() {
            self.nextPositionID = self.nextPositionID + 1
        }

        // --- Default Token ---

        access(all) view fun getDefaultToken(): Type {
            return self.defaultToken
        }

        // --- Stability Funds ---

        access(EImplementation) fun borrowStabilityFund(_ type: Type): auth(FungibleToken.Withdraw) &{FungibleToken.Vault}? {
            return &self.stabilityFunds[type]
        }

        access(all) view fun hasStabilityFund(_ type: Type): Bool {
            return self.stabilityFunds[type] != nil
        }

        access(all) view fun getStabilityFundBalance(_ type: Type): UFix64 {
            if let ref = &self.stabilityFunds[type] as &{FungibleToken.Vault}? {
                return ref.balance
            }
            return 0.0
        }

        access(EImplementation) fun initStabilityFund(_ type: Type, _ vault: @{FungibleToken.Vault}) {
            self.stabilityFunds[type] <-! vault
        }

        // --- Position Update Queue ---

        access(all) view fun getPositionsNeedingUpdatesLength(): Int {
            return self.positionsNeedingUpdates.length
        }

        access(EImplementation) fun removeFirstPositionNeedingUpdate(): UInt64 {
            return self.positionsNeedingUpdates.removeFirst()
        }

        access(all) view fun positionsNeedingUpdatesContains(_ pid: UInt64): Bool {
            return self.positionsNeedingUpdates.contains(pid)
        }

        access(EImplementation) fun appendPositionNeedingUpdate(_ pid: UInt64) {
            self.positionsNeedingUpdates.append(pid)
        }

        access(EImplementation) fun setPositionsNeedingUpdates(_ positions: [UInt64]) {
            self.positionsNeedingUpdates = positions
        }

        // --- Position Lock ---

        access(all) view fun isPositionLocked(_ pid: UInt64): Bool {
            return self.positionLock[pid] ?? false
        }

        access(EImplementation) fun setPositionLock(_ pid: UInt64, _ locked: Bool) {
            self.positionLock[pid] = locked
        }

        access(EImplementation) fun removePositionLock(_ pid: UInt64) {
            self.positionLock.remove(key: pid)
        }
    }

    /// Factory function to create a new PoolStateImpl resource.
    /// Required because Cadence resources can only be created within their containing contract.
    access(all) fun createPoolState(
        globalLedger: {Type: {TokenState}},
        reserves: @{Type: {FungibleToken.Vault}},
        insuranceFund: @MOET.Vault,
        nextPositionID: UInt64,
        defaultToken: Type,
        stabilityFunds: @{Type: {FungibleToken.Vault}},
        positionsNeedingUpdates: [UInt64],
        positionLock: {UInt64: Bool}
    ): @{PoolState} {
        return <- create PoolStateImpl(
            globalLedger: globalLedger,
            reserves: <-reserves,
            insuranceFund: <-insuranceFund,
            nextPositionID: nextPositionID,
            defaultToken: defaultToken,
            stabilityFunds: <-stabilityFunds,
            positionsNeedingUpdates: positionsNeedingUpdates,
            positionLock: positionLock
        )
    }
}
