import "Burner"
import "FungibleToken"
import "ViewResolver"
import "MetadataViews"
import "FungibleTokenMetadataViews"

import "DFBUtils"
import "DFB"
import "MOET"
import "TidalProtocolUtils"

access(all) contract TidalProtocol {

    /// The canonical StoragePath where the primary TidalProtocol Pool is stored
    access(all) let PoolStoragePath: StoragePath
    /// The canonical StoragePath where the PoolFactory resource is stored
    access(all) let PoolFactoryPath: StoragePath
    /// The canonical PublicPath where the primary TidalProtocol Pool can be accessed publicly
    access(all) let PoolPublicPath: PublicPath

    /* --- EVENTS ---- */

    access(all) event Opened(pid: UInt64, poolUUID: UInt64)
    access(all) event Deposited(pid: UInt64, poolUUID: UInt64, type: String, amount: UFix64, depositedUUID: UInt64)
    access(all) event Withdrawn(pid: UInt64, poolUUID: UInt64, type: String, amount: UFix64, withdrawnUUID: UInt64)
    access(all) event Rebalanced(pid: UInt64, poolUUID: UInt64, atHealth: UInt256, amount: UFix64, fromUnder: Bool)

    /* --- CONSTRUCTS & INTERNAL METHODS ---- */

    access(all) entitlement EPosition
    access(all) entitlement EGovernance
    access(all) entitlement EImplementation

    /// InternalBalance
    ///
    /// A structure used internally to track a position's balance for a particular token
    access(all) struct InternalBalance {
        /// The current direction of the balance - Credit (owed to borrower) or Debit (owed to protocol)
        access(all) var direction: BalanceDirection
        /// Internally, position balances are tracked using a "scaled balance". The "scaled balance" is the
        /// actual balance divided by the current interest index for the associated token. This means we don't
        /// need to update the balance of a position as time passes, even as interest rates change. We only need
        /// to update the scaled balance when the user deposits or withdraws funds. The interest index
        /// is a number relatively close to 1.0, so the scaled balance will be roughly of the same order
        /// of magnitude as the actual balance (thus we can use UFix64 for the scaled balance).
        access(all) var scaledBalance: UInt256

        init() {
            self.direction = BalanceDirection.Credit
            self.scaledBalance = 0
        }

        /// Records a deposit of the defined amount, updating the inner scaledBalance as well as relevant values in the
        /// provided TokenState. It's assumed the TokenState and InternalBalance relate to the same token Type, but
        /// since neither struct have values defining the associated token, callers should be sure to make the arguments
        /// do in fact relate to the same token Type.
        access(all) fun recordDeposit(amount: UInt256, tokenState: auth(EImplementation) &TokenState) {
            if self.direction == BalanceDirection.Credit {
                // Depositing into a credit position just increases the balance.

                // To maximize precision, we could convert the scaled balance to a true balance, add the
                // deposit amount, and then convert the result back to a scaled balance. However, this will
                // only cause problems for very small deposits (fractions of a cent), so we save computational
                // cycles by just scaling the deposit amount and adding it directly to the scaled balance.
                let scaledDeposit = TidalProtocol.trueBalanceToScaledBalance(amount,
                    interestIndex: tokenState.creditInterestIndex)

                self.scaledBalance = self.scaledBalance + scaledDeposit

                // Increase the total credit balance for the token
                tokenState.updateCreditBalance(amount: Int256(amount))
            } else {
                // When depositing into a debit position, we first need to compute the true balance to see
                // if this deposit will flip the position from debit to credit.
                let trueBalance = TidalProtocol.scaledBalanceToTrueBalance(self.scaledBalance,
                    interestIndex: tokenState.debitInterestIndex)

                if trueBalance > amount {
                    // The deposit isn't big enough to clear the debt, so we just decrement the debt.
                    let updatedBalance = trueBalance - amount

                    self.scaledBalance = TidalProtocol.trueBalanceToScaledBalance(updatedBalance,
                        interestIndex: tokenState.debitInterestIndex)

                    // Decrease the total debit balance for the token
                    tokenState.updateDebitBalance(amount: -1 * Int256(amount))
                } else {
                    // The deposit is enough to clear the debt, so we switch to a credit position.
                    let updatedBalance = amount - trueBalance

                    self.direction = BalanceDirection.Credit
                    self.scaledBalance = TidalProtocol.trueBalanceToScaledBalance(updatedBalance,
                        interestIndex: tokenState.creditInterestIndex)

                    // Increase the credit balance AND decrease the debit balance
                    tokenState.updateCreditBalance(amount: Int256(updatedBalance))
                    tokenState.updateDebitBalance(amount: -1 * Int256(trueBalance))
                }
            }
        }

        /// Records a withdrawal of the defined amount, updating the inner scaledBalance as well as relevant values in
        /// the provided TokenState. It's assumed the TokenState and InternalBalance relate to the same token Type, but
        /// since neither struct have values defining the associated token, callers should be sure to make the arguments
        /// do in fact relate to the same token Type.
        access(all) fun recordWithdrawal(amount: UInt256, tokenState: &TokenState) {
            if self.direction == BalanceDirection.Debit {
                // Withdrawing from a debit position just increases the debt amount.

                // To maximize precision, we could convert the scaled balance to a true balance, subtract the
                // withdrawal amount, and then convert the result back to a scaled balance. However, this will
                // only cause problems for very small withdrawals (fractions of a cent), so we save computational
                // cycles by just scaling the withdrawal amount and subtracting it directly from the scaled balance.
                let scaledWithdrawal = TidalProtocol.trueBalanceToScaledBalance(amount,
                    interestIndex: tokenState.debitInterestIndex)

                self.scaledBalance = self.scaledBalance + scaledWithdrawal

                // Increase the total debit balance for the token
                tokenState.updateDebitBalance(amount: Int256(amount))
            } else {
                // When withdrawing from a credit position, we first need to compute the true balance to see
                // if this withdrawal will flip the position from credit to debit.
                let trueBalance = TidalProtocol.scaledBalanceToTrueBalance(self.scaledBalance,
                    interestIndex: tokenState.creditInterestIndex)

                if trueBalance >= amount {
                    // The withdrawal isn't big enough to push the position into debt, so we just decrement the
                    // credit balance.
                    let updatedBalance = trueBalance - amount

                    self.scaledBalance = TidalProtocol.trueBalanceToScaledBalance(updatedBalance,
                        interestIndex: tokenState.creditInterestIndex)

                    // Decrease the total credit balance for the token
                    tokenState.updateCreditBalance(amount: -1 * Int256(amount))
                } else {
                    // The withdrawal is enough to push the position into debt, so we switch to a debit position.
                    let updatedBalance = amount - trueBalance

                    self.direction = BalanceDirection.Debit
                    self.scaledBalance = TidalProtocol.trueBalanceToScaledBalance(updatedBalance,
                        interestIndex: tokenState.debitInterestIndex)

                    // Decrease the credit balance AND increase the debit balance
                    tokenState.updateCreditBalance(amount: -1 * Int256(trueBalance))
                    tokenState.updateDebitBalance(amount: Int256(updatedBalance))
                }
            }
        }
    }

    /// BalanceSheet
    ///
    /// An struct containing a position's overview in terms of its effective collateral and debt as well as its
    /// current health
    access(all) struct BalanceSheet {
        /// A position's withdrawable value based on collateral deposits against the Pool's collateral and borrow factors
        access(all) let effectiveCollateral: UInt256
        /// A position's withdrawn value based on withdrawals against the Pool's collateral and borrow factors
        access(all) let effectiveDebt: UInt256
        /// The health of the related position
        access(all) let health: UInt256

        init(effectiveCollateral: UInt256, effectiveDebt: UInt256) {
            self.effectiveCollateral = effectiveCollateral
            self.effectiveDebt = effectiveDebt
            self.health = TidalProtocol.healthComputation(effectiveCollateral: effectiveCollateral, effectiveDebt: effectiveDebt)
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
        /// The target health of the position
        access(EImplementation) var targetHealth: UFix64
        /// The minimum health of the position, below which a position is considered undercollateralized
        access(EImplementation) var minHealth: UFix64
        /// The maximum health of the position, above which a position is considered overcollateralized
        access(EImplementation) var maxHealth: UFix64
        /// The balances of deposited and withdrawn token types
        access(mapping ImplementationUpdates) var balances: {Type: InternalBalance}
        /// Funds that have been deposited but must be asynchronously added to the Pool's reserves and recorded
        access(mapping ImplementationUpdates) var queuedDeposits: @{Type: {FungibleToken.Vault}}
        /// A DeFiBlocks Sink that if non-nil will enable the Pool to push overflown value automatically when the
        /// position exceeds its maximum health based on the value of deposited collateral versus withdrawals
        access(mapping ImplementationUpdates) var drawDownSink: {DFB.Sink}?
        /// A DeFiBlocks Source that if non-nil will enable the Pool to pull underflown value automatically when the
        /// position falls below its minimum health based on the value of deposited collateral versus withdrawals. If
        /// this value is not set, liquidation may occur in the event of undercollateralization.
        access(mapping ImplementationUpdates) var topUpSource: {DFB.Source}?

        init() {
            self.balances = {}
            self.queuedDeposits <- {}
            self.targetHealth = 1.3
            self.minHealth = 1.1
            self.maxHealth = 1.5
            self.drawDownSink = nil
            self.topUpSource = nil
        }

        access(all) view fun intMinHealth(): UInt256 {
            return TidalProtocolUtils.ufix64ToUInt256(self.minHealth, decimals: TidalProtocolUtils.decimals)
        }
        access(all) view fun intMaxHealth(): UInt256 {
            return TidalProtocolUtils.ufix64ToUInt256(self.maxHealth, decimals: TidalProtocolUtils.decimals)
        }
        access(all) view fun intTargetHealth(): UInt256 {
            return TidalProtocolUtils.ufix64ToUInt256(self.targetHealth, decimals: TidalProtocolUtils.decimals)
        }
        /// Sets the InternalPosition's drawDownSink. If `nil`, the Pool will not be able to push overflown value when
        /// the position exceeds its maximum health. Note, if a non-nil value is provided, the Sink MUST accept MOET
        /// deposits or the operation will revert.
        access(EImplementation) fun setDrawDownSink(_ sink: {DFB.Sink}?) {
            pre {
                sink?.getSinkType() ?? Type<@MOET.Vault>() == Type<@MOET.Vault>():
                "Invalid Sink provided - Sink \(sink.getType().identifier) must accept MOET"
            }
            self.drawDownSink = sink
        }
        /// Sets the InternalPosition's topUpSource. If `nil`, the Pool will not be able to pull underflown value when
        /// the position falls below its minimum health which may result in liquidation.
        access(EImplementation) fun setTopUpSource(_ source: {DFB.Source}?) {
            self.topUpSource = source
        }
    }

    /// InterestCurve
    ///
    /// A simple interface to calculate interest rate
    access(all) struct interface InterestCurve {
        access(all) fun interestRate(creditBalance: UInt256, debitBalance: UInt256): UInt64 {
            post {
                result <= UInt64(TidalProtocolUtils.e18): "Interest rate can't exceed 100%"
            }
        }
    }

    /// SimpleInterestCurve
    ///
    /// A simple implementation of the InterestCurve interface.
    access(all) struct SimpleInterestCurve: InterestCurve {
        access(all) fun interestRate(creditBalance: UInt256, debitBalance: UInt256): UInt64 {
            return 0 // TODO
        }
    }

    /// TokenState
    ///
    /// The TokenState struct tracks values related to a single token Type within the Pool.
    access(all) struct TokenState {
        /// The timestamp at which the TokenState was last updated
        access(all) var lastUpdate: UFix64
        /// The total credit balance of the related Token across the whole Pool in which this TokenState resides
        access(all) var totalCreditBalance: UInt256
        /// The total debit balance of the related Token across the whole Pool in which this TokenState resides
        access(all) var totalDebitBalance: UInt256
        /// The index of the credit interest for the related token. Interest on a token is stored as an "index" which
        /// can be thought of as “how many actual tokens does 1 unit of scaled balance represent right now?”
        access(all) var creditInterestIndex: UInt256
        /// The index of the debit interest for the related token. Interest on a token is stored as an "index" which
        /// can be thought of as “how many actual tokens does 1 unit of scaled balance represent right now?”
        access(all) var debitInterestIndex: UInt256
        /// The interest rate for credit of the associated token
        access(all) var currentCreditRate: UInt64
        /// The interest rate for debit of the associated token
        access(all) var currentDebitRate: UInt64
        /// The interest curve implementation used to calculate interest rate
        access(all) var interestCurve: {InterestCurve}
        /// The rate at which depositCapacity can increase over time
        access(all) var depositRate: UFix64
        /// The limit on deposits of the related token
        access(all) var depositCapacity: UFix64
        /// The upper bound on total deposits of the related token, limiting how much depositCapacity can reach
        access(all) var depositCapacityCap: UFix64

        init(interestCurve: {InterestCurve}, depositRate: UFix64, depositCapacityCap: UFix64) {
            self.lastUpdate = getCurrentBlock().timestamp
            self.totalCreditBalance = 0
            self.totalDebitBalance = 0
            self.creditInterestIndex = TidalProtocolUtils.e18
            self.debitInterestIndex = TidalProtocolUtils.e18
            self.currentCreditRate = UInt64(TidalProtocolUtils.e18)
            self.currentDebitRate = UInt64(TidalProtocolUtils.e18)
            self.interestCurve = interestCurve
            self.depositRate = depositRate
            self.depositCapacity = depositCapacityCap
            self.depositCapacityCap = depositCapacityCap
        }

        /// Updates the totalCreditBalance by the provided amount
        access(all) fun updateCreditBalance(amount: Int256) {
            // temporary cast the credit balance to a signed value so we can add/subtract
            let adjustedBalance = Int256(self.totalCreditBalance) + amount
            self.totalCreditBalance = adjustedBalance > 0 ? UInt256(adjustedBalance) : 0
        }

        access(all) fun updateDebitBalance(amount: Int256) {
            // temporary cast the debit balance to a signed value so we can add/subtract
            let adjustedBalance = Int256(self.totalDebitBalance) + amount
            self.totalDebitBalance = adjustedBalance > 0 ? UInt256(adjustedBalance) : 0
        }

        // Enhanced updateInterestIndices with deposit capacity update
        access(all) fun updateInterestIndices() {
            let currentTime = getCurrentBlock().timestamp
            let timeDelta: UFix64 = currentTime - self.lastUpdate
            self.creditInterestIndex = TidalProtocol.compoundInterestIndex(oldIndex: self.creditInterestIndex, perSecondRate: self.currentCreditRate, elapsedSeconds: timeDelta)
            self.debitInterestIndex = TidalProtocol.compoundInterestIndex(oldIndex: self.debitInterestIndex, perSecondRate: self.currentDebitRate, elapsedSeconds: timeDelta)
            self.lastUpdate = currentTime

            // Update deposit capacity based on time
            let newDepositCapacity = self.depositCapacity + (self.depositRate * timeDelta)
            if newDepositCapacity >= self.depositCapacityCap {
                self.depositCapacity = self.depositCapacityCap
            } else {
                self.depositCapacity = newDepositCapacity
            }
        }

        // Deposit limit function
        access(all) fun depositLimit(): UFix64 {
            // Each deposit is limited to 5% of the total deposit capacity
            return self.depositCapacity * 0.05
        }

        access(all) fun updateForTimeChange() {
            self.updateInterestIndices()
        }

        access(all) fun updateInterestRates() {
            // If there's no credit balance, we can't calculate a meaningful credit rate
            // so we'll just set both rates to zero and return early
            if self.totalCreditBalance <= 0 {
                self.currentCreditRate = UInt64(TidalProtocolUtils.e18)  // 1.0 in fixed point (no interest)
                self.currentDebitRate = UInt64(TidalProtocolUtils.e18)   // 1.0 in fixed point (no interest)
                return
            }

            let debitRate = self.interestCurve.interestRate(creditBalance: self.totalCreditBalance, debitBalance: self.totalDebitBalance)
            let debitIncome = TidalProtocolUtils.mul(self.totalDebitBalance, TidalProtocolUtils.e18) + UInt256(debitRate)

            // Calculate insurance amount (0.1% of credit balance)
            let insuranceAmount = TidalProtocolUtils.mul(self.totalCreditBalance, 1_000_000_000_000_000)  // * 0.001 (18 decimal places)

            // Calculate credit rate, ensuring we don't have underflows
            var creditRate: UInt256 = 0
            if debitIncome >= insuranceAmount {
                creditRate = ((debitIncome - insuranceAmount) / self.totalCreditBalance) - TidalProtocolUtils.e18
            } else {
                // If debit income doesn't cover insurance, we have a negative credit rate
                // but since we can't represent negative rates in our model, we'll use 0
                creditRate = 0
            }

            self.currentCreditRate = TidalProtocol.perSecondInterestRate(yearlyRate: UInt64(creditRate))
            self.currentDebitRate = TidalProtocol.perSecondInterestRate(yearlyRate: UInt64(debitRate))
        }
    }

    /// Pool
    ///
    /// A Pool is the primary logic for protocol operations. It contains the global state of all positions, credit and
    /// debit balances for each supported token type, and reserves as they are deposited to positions.
    access(all) resource Pool {
        /// Global state for tracking each token
        access(self) var globalLedger: {Type: TokenState}
        /// Individual user positions
        access(self) var positions: @{UInt64: InternalPosition}
        /// The actual reserves of each token
        access(self) var reserves: @{Type: {FungibleToken.Vault}}
        /// Auto-incrementing position identifier counter
        access(self) var nextPositionID: UInt64
        /// The default token type used as the "unit of account" for the pool.
        access(self) let defaultToken: Type
        /// A price oracle that will return the price of each token in terms of the default token.
        access(self) var priceOracle: {DFB.PriceOracle}
        /// Together with borrowFactor, collateralFactor determines borrowing limits for each token
        /// When determining the withdrawable loan amount, the value of the token (provided by the PriceOracle) is
        /// multiplied by the collateral factor. The total "effective collateral" for a position is the value of each
        /// token deposited to the position multiplied by its collateral factor
        access(self) var collateralFactor: {Type: UFix64}
        /// Together with collateralFactor, borrowFactor determines borrowing limits for each token
        /// The borrowFactor determines how much of a position's "effective collateral" can be borrowed against as a
        /// percentage between 0.0 and 1.0
        access(self) var borrowFactor: {Type: UFix64}
        /// The count of positions to update per asynchronous update
        access(self) var positionsProcessedPerCallback: UInt64
        /// Position update queue to be processed as an asynchronous update
        access(EImplementation) var positionsNeedingUpdates: [UInt64]
        /// A simple version number that is incremented whenever one or more interest indices are updated. This is used
        /// to detect when the interest indices need to be updated in InternalPositions.
        access(EImplementation) var version: UInt64

        init(defaultToken: Type, priceOracle: {DFB.PriceOracle}) {
            pre {
                priceOracle.unitOfAccount() == defaultToken: "Price oracle must return prices in terms of the default token"
            }

            self.version = 0
            self.globalLedger = {defaultToken: TokenState(
                interestCurve: SimpleInterestCurve(),
                depositRate: 1_000_000.0,        // Default: no rate limiting for default token
                depositCapacityCap: 1_000_000.0  // Default: high capacity cap
            )}
            self.positions <- {}
            self.reserves <- {}
            self.defaultToken = defaultToken
            self.priceOracle = priceOracle
            self.collateralFactor = {defaultToken: 1.0}
            self.borrowFactor = {defaultToken: 1.0}
            self.nextPositionID = 0
            self.positionsNeedingUpdates = []
            self.positionsProcessedPerCallback = 100

            // CHANGE: Don't create vault here - let the caller provide initial reserves
            // The pool starts with empty reserves map
            // Vaults will be added when tokens are first deposited
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

        /// Returns the current reserve balance for the specified token type.
        access(all) view fun reserveBalance(type: Type): UFix64 {
            let vaultRef = (&self.reserves[type] as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?)
            if vaultRef == nil {
                return 0.0
            }
            return vaultRef!.balance
        }

        /// Returns a position's balance available for withdrawal of a given Vault type. If pullFromTopUpSource is true,
        /// the calculation will be made assuming the position is topped up if the withdrawal amount puts the Position
        /// below its min health. If pullFromTopUpSource is true, the calculation will return the balance currently
        /// available without topping up the position.
        access(all) fun availableBalance(pid: UInt64, type: Type, pullFromTopUpSource: Bool): UFix64 {
            log("    [CONTRACT] availableBalance(pid: \(pid), type: \(type.contractName!), pullFromTopUpSource: \(pullFromTopUpSource))")
            let position = self._borrowPosition(pid: pid)

            if pullFromTopUpSource && position.topUpSource != nil {
                let topUpSource = position.topUpSource!
                let sourceType = topUpSource.getSourceType()
                let sourceAmount = topUpSource.minimumAvailable()
                log("    [CONTRACT] Calling to fundsAvailableAboveTargetHealthAfterDepositing with sourceAmount \(sourceAmount) and targetHealth \(position.minHealth)")

                return self.fundsAvailableAboveTargetHealthAfterDepositing(
                    pid: pid,
                    withdrawType: type,
                    targetHealth: position.minHealth,
                    depositType: sourceType,
                    depositAmount: sourceAmount
                )
            } else {
                log("    [CONTRACT] Calling to fundsAvailableAboveTargetHealth with targetHealth \(position.minHealth)")
                return self.fundsAvailableAboveTargetHealth(
                    pid: pid,
                    type: type,
                    targetHealth: position.minHealth
                )
            }
        }

        /// Returns the health of the given position, which is the ratio of the position's effective collateral to its
        /// debt as denominated in the Pool's default token. "Effective collateral" means the value of each credit balance
        /// times the liquidation threshold for that token. i.e. the maximum borrowable amount
        access(all) fun positionHealth(pid: UInt64): UInt256 {
            let position = self._borrowPosition(pid: pid)

            // Get the position's collateral and debt values in terms of the default token.
            var effectiveCollateral: UInt256 = 0
            var effectiveDebt: UInt256 = 0

            for type in position.balances.keys {
                let balance = position.balances[type]!
                let tokenState = self._borrowUpdatedTokenState(type: type)

                let uintCollateralFactor = TidalProtocolUtils.ufix64ToUInt256(self.collateralFactor[type]!, decimals: TidalProtocolUtils.decimals)
                let uintBorrowFactor = TidalProtocolUtils.ufix64ToUInt256(self.borrowFactor[type]!, decimals: TidalProtocolUtils.decimals)
                let uintPrice = TidalProtocolUtils.ufix64ToUInt256(self.priceOracle.price(ofToken: type)!, decimals: TidalProtocolUtils.decimals)
                if balance.direction == BalanceDirection.Credit {
                    let trueBalance = TidalProtocol.scaledBalanceToTrueBalance(balance.scaledBalance,
                        interestIndex: tokenState.creditInterestIndex)

                    let value = TidalProtocolUtils.mul(uintPrice, trueBalance)
                    let effectiveCollateralValue = TidalProtocolUtils.mul(value, uintCollateralFactor)
                    effectiveCollateral = effectiveCollateral + effectiveCollateralValue
                } else {
                    let trueBalance = TidalProtocol.scaledBalanceToTrueBalance(balance.scaledBalance,
                        interestIndex: tokenState.debitInterestIndex)

                    let value = TidalProtocolUtils.mul(uintPrice, trueBalance)
                    let effectiveDebtValue = TidalProtocolUtils.div(value, uintBorrowFactor)
                    effectiveDebt = effectiveDebt + effectiveDebtValue
                }
            }

            // Calculate the health as the ratio of collateral to debt.
            return TidalProtocol.healthComputation(effectiveCollateral: effectiveCollateral, effectiveDebt: effectiveDebt)
        }

        /// Returns the quantity of funds of a specified token which would need to be deposited to bring the position to
        /// the provided target health. This function will return 0.0 if the position is already at or over that health
        /// value.
        access(all) fun fundsRequiredForTargetHealth(pid: UInt64, type: Type, targetHealth: UFix64): UFix64 {
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
            let position = self._borrowPosition(pid: pid)
            let balances: [PositionBalance] = []

            for type in position.balances.keys {
                let balance = position.balances[type]!
                let tokenState = self._borrowUpdatedTokenState(type: type)
                let trueBalance = balance.direction == BalanceDirection.Credit
                    ? TidalProtocol.scaledBalanceToTrueBalance(balance.scaledBalance, interestIndex: tokenState.creditInterestIndex)
                    : TidalProtocol.scaledBalanceToTrueBalance(balance.scaledBalance, interestIndex: tokenState.debitInterestIndex)

                balances.append(PositionBalance(
                    vaultType: type,
                    direction: balance.direction,
                    balance: TidalProtocolUtils.uint256ToUFix64(trueBalance, decimals: TidalProtocolUtils.decimals)
                ))
            }

            let health = self.positionHealth(pid: pid)
            let defaultTokenAvailable = self.availableBalance(pid: pid, type: self.defaultToken, pullFromTopUpSource: false)

            return PositionDetails(
                balances: balances,
                poolDefaultToken: self.defaultToken,
                defaultTokenAvailableBalance: defaultTokenAvailable,
                health: health
            )
        }

        /// Returns the quantity of funds of a specified token which would need to be deposited in order to bring the
        /// position to the target health assuming we also withdraw a specified amount of another token. This function
        /// will return 0.0 if the position would already be at or over the target health value after the proposed
        /// withdrawal.
        access(all) fun fundsRequiredForTargetHealthAfterWithdrawing(
            pid: UInt64,
            depositType: Type,
            targetHealth: UFix64,
            withdrawType: Type,
            withdrawAmount: UFix64
        ): UFix64 {
            if depositType == withdrawType && withdrawAmount > 0.0 {
                // If the deposit and withdrawal types are the same, we compute the required deposit assuming
                // no withdrawal (which is less work) and increase that by the withdraw amount at the end
                return self.fundsRequiredForTargetHealth(pid: pid, type: depositType, targetHealth: targetHealth) + withdrawAmount
            }

            let balanceSheet = self._getUpdatedBalanceSheet(pid: pid)
            let position = self._borrowPosition(pid: pid)

            var effectiveCollateralAfterWithdrawal = balanceSheet.effectiveCollateral
            var effectiveDebtAfterWithdrawal = balanceSheet.effectiveDebt

            let uintWithdrawAmount = TidalProtocolUtils.ufix64ToUInt256(withdrawAmount, decimals: TidalProtocolUtils.decimals)
            let uintWithdrawPrice = TidalProtocolUtils.ufix64ToUInt256(self.priceOracle.price(ofToken: withdrawType)!, decimals: TidalProtocolUtils.decimals)
            let uintWithdrawBorrowFactor = TidalProtocolUtils.ufix64ToUInt256(self.borrowFactor[withdrawType]!, decimals: TidalProtocolUtils.decimals)
            if withdrawAmount != 0.0 {
                if position.balances[withdrawType] == nil || position.balances[withdrawType]!.direction == BalanceDirection.Debit {
                    // If the position doesn't have any collateral for the withdrawn token, we can just compute how much
                    // additional effective debt the withdrawal will create.
                    effectiveDebtAfterWithdrawal = balanceSheet.effectiveDebt +
                        TidalProtocolUtils.div(TidalProtocolUtils.mul(uintWithdrawAmount, uintWithdrawPrice), uintWithdrawBorrowFactor)
                } else {
                    let withdrawTokenState = self._borrowUpdatedTokenState(type: withdrawType)

                    // The user has a collateral position in the given token, we need to figure out if this withdrawal
                    // will flip over into debt, or just draw down the collateral.
                    let collateralBalance = position.balances[withdrawType]!.scaledBalance
                    let trueCollateral = TidalProtocol.scaledBalanceToTrueBalance(collateralBalance,
                        interestIndex: withdrawTokenState.creditInterestIndex
                    )
                    let uintCollateralFactor = TidalProtocolUtils.ufix64ToUInt256(self.collateralFactor[withdrawType]!, decimals: TidalProtocolUtils.decimals)
                    if trueCollateral >= uintWithdrawAmount {
                        // This withdrawal will draw down collateral, but won't create debt, we just need to account
                        // for the collateral decrease.
                        effectiveCollateralAfterWithdrawal = balanceSheet.effectiveCollateral -
                            TidalProtocolUtils.mul(TidalProtocolUtils.mul(uintWithdrawAmount, uintWithdrawPrice), uintCollateralFactor)
                    } else {
                        // The withdrawal will wipe out all of the collateral, and create some debt.
                        effectiveDebtAfterWithdrawal = balanceSheet.effectiveDebt +
                            TidalProtocolUtils.div(TidalProtocolUtils.mul(uintWithdrawAmount - trueCollateral, uintWithdrawPrice), uintWithdrawBorrowFactor)
                        effectiveCollateralAfterWithdrawal = balanceSheet.effectiveCollateral -
                            TidalProtocolUtils.mul(TidalProtocolUtils.mul(trueCollateral, uintWithdrawPrice), uintCollateralFactor)
                    }
                }
            }

            // We now have new effective collateral and debt values that reflect the proposed withdrawal (if any!)
            // Now we can figure out how many of the given token would need to be deposited to bring the position
            // to the target health value.
            var healthAfterWithdrawal = TidalProtocol.healthComputation(
                effectiveCollateral: effectiveCollateralAfterWithdrawal,
                effectiveDebt: effectiveDebtAfterWithdrawal
            )

            let uintTargetHealth = TidalProtocolUtils.ufix64ToUInt256(targetHealth, decimals: TidalProtocolUtils.decimals)
            if healthAfterWithdrawal >= uintTargetHealth {
                // The position is already at or above the target health, so we don't need to deposit anything.
                return 0.0
            }

            // For situations where the required deposit will BOTH pay off debt and accumulate collateral, we keep
            // track of the number of tokens that went towards paying off debt.
            var debtTokenCount: UInt256 = 0
            let uintDepositPrice = TidalProtocolUtils.ufix64ToUInt256(self.priceOracle.price(ofToken: withdrawType)!, decimals: TidalProtocolUtils.decimals)
            let uintDepositBorrowFactor = TidalProtocolUtils.ufix64ToUInt256(self.borrowFactor[withdrawType]!, decimals: TidalProtocolUtils.decimals)
            if position.balances[depositType] != nil && position.balances[depositType]!.direction == BalanceDirection.Debit {
                // The user has a debt position in the given token, we start by looking at the health impact of paying off
                // the entire debt.
                let depositTokenState = self._borrowUpdatedTokenState(type: depositType)
                // REMOVED: This is now handled by tokenState() helper function
                // depositTokenState.updateForTimeChange()
                let debtBalance = position.balances[depositType]!.scaledBalance
                let trueDebt = TidalProtocol.scaledBalanceToTrueBalance(debtBalance,
                    interestIndex: depositTokenState.debitInterestIndex
                )
                let debtEffectiveValue = TidalProtocolUtils.div(TidalProtocolUtils.mul(uintDepositPrice, trueDebt), uintDepositBorrowFactor)

                // Ensure we don't underflow - if debtEffectiveValue is greater than effectiveDebtAfterWithdrawal,
                // it means we can pay off all debt
                var effectiveDebtAfterPayment: UInt256 = 0
                if debtEffectiveValue <= effectiveDebtAfterWithdrawal {
                    effectiveDebtAfterPayment = effectiveDebtAfterWithdrawal - debtEffectiveValue
                }

                // Check what the new health would be if we paid off all of this debt
                let potentialHealth = TidalProtocol.healthComputation(
                    effectiveCollateral: effectiveCollateralAfterWithdrawal,
                    effectiveDebt: effectiveDebtAfterPayment
                )

                // Does paying off all of the debt reach the target health? Then we're done.
                if potentialHealth >= uintTargetHealth {
                    // We can reach the target health by paying off some or all of the debt. We can easily
                    // compute how many units of the token would be needed to reach the target health.
                    let healthChange = uintTargetHealth - healthAfterWithdrawal
                    let requiredEffectiveDebt = effectiveDebtAfterWithdrawal - TidalProtocolUtils.div(
                            effectiveCollateralAfterWithdrawal,
                            TidalProtocolUtils.ufix64ToUInt256(targetHealth, decimals: TidalProtocolUtils.decimals)
                        )

                    // The amount of the token to pay back, in units of the token.
                    let paybackAmount = TidalProtocolUtils.div(
                            TidalProtocolUtils.mul(requiredEffectiveDebt, uintDepositBorrowFactor),
                            uintDepositPrice
                        )

                    return TidalProtocolUtils.uint256ToUFix64(paybackAmount, decimals: TidalProtocolUtils.decimals)
                } else {
                    // We can pay off the entire debt, but we still need to deposit more to reach the target health.
                    // We have logic below that can determine the collateral deposition required to reach the target health
                    // from this new health position. Rather than copy that logic here, we fall through into it. But first
                    // we have to record the amount of tokens that went towards debt payback and adjust the effective
                    // debt to reflect that it has been paid off.
                    debtTokenCount = trueDebt
                    // Ensure we don't underflow
                    if debtEffectiveValue <= effectiveDebtAfterWithdrawal {
                        effectiveDebtAfterWithdrawal = effectiveDebtAfterWithdrawal - debtEffectiveValue
                    } else {
                        effectiveDebtAfterWithdrawal = 0
                    }
                    healthAfterWithdrawal = potentialHealth
                }
            }

            // At this point, we're either dealing with a position that didn't have a debt position in the deposit
            // token, or we've accounted for the debt payoff and adjusted the effective debt above.

            // Now we need to figure out how many tokens would need to be deposited (as collateral) to reach the
            // target health. We can rearrange the health equation to solve for the required collateral:
            // targetHealth = effectiveCollateral / effectiveDebt
            // targetHealth * effectiveDebt = effectiveCollateral
            // requiredCollateral = targetHealth * effectiveDebtAfterWithdrawal

            // We need to increase the effective collateral from its current value to the required value, so we
            // multiply the required health change by the effective debt, and turn that into a token amount.
            let uintHealthChange = uintTargetHealth - healthAfterWithdrawal
            let requiredEffectiveCollateral = TidalProtocolUtils.mul(uintHealthChange, effectiveDebtAfterWithdrawal)

            // The amount of the token to deposit, in units of the token.
            let collateralTokenCount = TidalProtocolUtils.div(requiredEffectiveCollateral, uintDepositPrice)

            // debtTokenCount is the number of tokens that went towards debt, zero if there was no debt.
            return TidalProtocolUtils.uint256ToUFix64(collateralTokenCount + debtTokenCount, decimals: TidalProtocolUtils.decimals)
        }

        /// Returns the quantity of the specified token that could be withdrawn while still keeping the position's
        /// health at or above the provided target.
        access(all) fun fundsAvailableAboveTargetHealth(pid: UInt64, type: Type, targetHealth: UFix64): UFix64 {
            return self.fundsAvailableAboveTargetHealthAfterDepositing(
                pid: pid,
                withdrawType: type,
                targetHealth: targetHealth,
                depositType: self.defaultToken,
                depositAmount: 0.0
            )
        }

        /// Returns the quantity of the specified token that could be withdrawn while still keeping the position's health
        /// at or above the provided target, assuming we also deposit a specified amount of another token.
        access(all) fun fundsAvailableAboveTargetHealthAfterDepositing(
            pid: UInt64,
            withdrawType: Type,
            targetHealth: UFix64,
            depositType: Type,
            depositAmount: UFix64
        ): UFix64 {
            log("    [CONTRACT] fundsAvailableAboveTargetHealthAfterDepositing(pid: \(pid), withdrawType: \(withdrawType.contractName!), targetHealth: \(targetHealth), depositType: \(depositType.contractName!), depositAmount: \(depositAmount))")
            if depositType == withdrawType && depositAmount > 0.0 {
                // If the deposit and withdrawal types are the same, we compute the available funds assuming
                // no deposit (which is less work) and increase that by the deposit amount at the end
                return self.fundsAvailableAboveTargetHealth(pid: pid, type: withdrawType, targetHealth: targetHealth) + depositAmount
            }

            let balanceSheet = self._getUpdatedBalanceSheet(pid: pid)
            let position = self._borrowPosition(pid: pid)

            var effectiveCollateralAfterDeposit = balanceSheet.effectiveCollateral
            var effectiveDebtAfterDeposit = balanceSheet.effectiveDebt
            log("    [CONTRACT] effectiveCollateralAfterDeposit: \(effectiveCollateralAfterDeposit)")
            log("    [CONTRACT] effectiveDebtAfterDeposit: \(effectiveDebtAfterDeposit)")

            let uintDepositAmount = TidalProtocolUtils.ufix64ToUInt256(depositAmount, decimals: TidalProtocolUtils.decimals)
            let uintDepositPrice = TidalProtocolUtils.ufix64ToUInt256(self.priceOracle.price(ofToken: depositType)!, decimals: TidalProtocolUtils.decimals)
            let uintDepositBorrowFactor = TidalProtocolUtils.ufix64ToUInt256(self.borrowFactor[depositType]!, decimals: TidalProtocolUtils.decimals)
            let uintDepositCollateralFactor = TidalProtocolUtils.ufix64ToUInt256(self.collateralFactor[depositType]!, decimals: TidalProtocolUtils.decimals)

            if depositAmount != 0.0 {
                if position.balances[depositType] == nil || position.balances[depositType]!.direction == BalanceDirection.Credit {
                    // If there's no debt for the deposit token, we can just compute how much additional effective collateral the deposit will create.
                    effectiveCollateralAfterDeposit = balanceSheet.effectiveCollateral +
                        TidalProtocolUtils.mul(TidalProtocolUtils.mul(uintDepositAmount, uintDepositPrice), uintDepositCollateralFactor)
                } else {
                    let depositTokenState = self._borrowUpdatedTokenState(type: depositType)

                    // The user has a debt position in the given token, we need to figure out if this deposit
                    // will result in net collateral, or just bring down the debt.
                    let debtBalance = position.balances[depositType]!.scaledBalance
                    let trueDebt = TidalProtocol.scaledBalanceToTrueBalance(debtBalance,
                        interestIndex: depositTokenState.debitInterestIndex
                    )
                    log("    [CONTRACT] trueDebt: \(trueDebt)")

                    if trueDebt >= uintDepositAmount {
                        // This deposit will pay down some debt, but won't result in net collateral, we
                        // just need to account for the debt decrease.
                        // TODO - validate if this should deal with withdrawType or depositType
                        effectiveDebtAfterDeposit = balanceSheet.effectiveDebt -
                            TidalProtocolUtils.div(TidalProtocolUtils.mul(uintDepositAmount, uintDepositPrice), uintDepositBorrowFactor)
                    } else {
                        // The deposit will wipe out all of the debt, and create some collateral.
                        // TODO - validate if this should deal with withdrawType or depositType
                        effectiveDebtAfterDeposit = balanceSheet.effectiveDebt -
                            TidalProtocolUtils.div(TidalProtocolUtils.mul(trueDebt, uintDepositPrice), uintDepositBorrowFactor)
                        effectiveCollateralAfterDeposit = balanceSheet.effectiveCollateral +
                            TidalProtocolUtils.mul(TidalProtocolUtils.mul(uintDepositAmount - trueDebt, uintDepositPrice), uintDepositCollateralFactor)
                    }
                }
            }
            log("    [CONTRACT] effectiveCollateralAfterDeposit: \(effectiveCollateralAfterDeposit)")
            log("    [CONTRACT] effectiveDebtAfterDeposit: \(effectiveDebtAfterDeposit)")

            // We now have new effective collateral and debt values that reflect the proposed deposit (if any!)
            // Now we can figure out how many of the withdrawal token are available while keeping the position
            // at or above the target health value.
            var healthAfterDeposit = TidalProtocol.healthComputation(
                effectiveCollateral: effectiveCollateralAfterDeposit,
                effectiveDebt: effectiveDebtAfterDeposit
            )
            log("    [CONTRACT] healthAfterDeposit: \(healthAfterDeposit)")

            let uintTargetHealth = TidalProtocolUtils.ufix64ToUInt256(targetHealth, decimals: TidalProtocolUtils.decimals)
            if healthAfterDeposit <= uintTargetHealth {
                // The position is already at or below the provided target health, so we can't withdraw anything.
                return 0.0
            }

            // For situations where the available withdrawal will BOTH draw down collateral and create debt, we keep
            // track of the number of tokens that are available from collateral
            var collateralTokenCount: UInt256 = 0

            let uintWithdrawPrice = TidalProtocolUtils.ufix64ToUInt256(self.priceOracle.price(ofToken: withdrawType)!, decimals: TidalProtocolUtils.decimals)
            let uintWithdrawCollateralFactor = TidalProtocolUtils.ufix64ToUInt256(self.collateralFactor[withdrawType]!, decimals: TidalProtocolUtils.decimals)
            let uintWithdrawBorrowFactor = TidalProtocolUtils.ufix64ToUInt256(self.borrowFactor[withdrawType]!, decimals: TidalProtocolUtils.decimals)
            if position.balances[withdrawType] != nil && position.balances[withdrawType]!.direction == BalanceDirection.Credit {
                // The user has a credit position in the withdraw token, we start by looking at the health impact of pulling out all
                // of that collateral
                let withdrawTokenState = self._borrowUpdatedTokenState(type: withdrawType)
                let creditBalance = position.balances[withdrawType]!.scaledBalance
                let trueCredit = TidalProtocol.scaledBalanceToTrueBalance(creditBalance,
                    interestIndex: withdrawTokenState.creditInterestIndex
                )
                let collateralEffectiveValue = TidalProtocolUtils.mul(TidalProtocolUtils.mul(uintWithdrawPrice, trueCredit), uintWithdrawCollateralFactor)

                // Check what the new health would be if we took out all of this collateral
                let potentialHealth = TidalProtocol.healthComputation(
                    effectiveCollateral: effectiveCollateralAfterDeposit - collateralEffectiveValue, // ??? - why subtract?
                    effectiveDebt: effectiveDebtAfterDeposit
                )


                // Does drawing down all of the collateral go below the target health? Then the max withdrawal comes from collateral only.
                if potentialHealth <= uintTargetHealth {
                    // We will hit the health target before using up all of the withdraw token credit. We can easily
                    // compute how many units of the token would bring the position down to the target health.
                    let availableHealth = healthAfterDeposit == UInt256.max ? UInt256.max : healthAfterDeposit - uintTargetHealth
                    let availableEffectiveValue = (effectiveDebtAfterDeposit == 0 || availableHealth == UInt256.max)
                        ? effectiveCollateralAfterDeposit
                        : TidalProtocolUtils.mul(availableHealth, effectiveDebtAfterDeposit)
                    log("    [CONTRACT] availableHealth: \(availableHealth)")
                    log("    [CONTRACT] availableEffectiveValue: \(availableEffectiveValue)")

                    // The amount of the token we can take using that amount of health
                    // let availableTokenCount = availableEffectiveValue / self.collateralFactor[withdrawType]! / self.priceOracle.price(ofToken: withdrawType)!
                    let availableTokenCount = TidalProtocolUtils.div(TidalProtocolUtils.div(availableEffectiveValue, uintWithdrawCollateralFactor), uintWithdrawPrice)
                    log("    [CONTRACT] availableTokenCount: \(availableTokenCount)")

                    return TidalProtocolUtils.uint256ToUFix64(availableTokenCount, decimals: TidalProtocolUtils.decimals)
                } else {
                    // We can flip this credit position into a debit position, before hitting the target health.
                    // We have logic below that can determine health changes for debit positions. We've copied it here
                    // with an added handling for the case where the health after deposit is an edgecase
                    collateralTokenCount = trueCredit
                    effectiveCollateralAfterDeposit = effectiveCollateralAfterDeposit - collateralEffectiveValue
                    log("    [CONTRACT] collateralTokenCount: \(collateralTokenCount)")
                    log("    [CONTRACT] effectiveCollateralAfterDeposit: \(effectiveCollateralAfterDeposit)")

                    // We can calculate the available debt increase that would bring us to the target health
                    let uintTargetHealth = TidalProtocolUtils.ufix64ToUInt256(targetHealth, decimals: TidalProtocolUtils.decimals)
                    var availableDebtIncrease = TidalProtocolUtils.div(effectiveCollateralAfterDeposit, uintTargetHealth) - effectiveDebtAfterDeposit
                    let availableTokens = TidalProtocolUtils.div(TidalProtocolUtils.mul(availableDebtIncrease, uintWithdrawBorrowFactor), uintWithdrawPrice)
                    log("    [CONTRACT] availableDebtIncrease: \(availableDebtIncrease)")
                    log("    [CONTRACT] availableTokens: \(availableTokens)")
                    log("    [CONTRACT] availableTokens + collateralTokenCount: \(availableTokens + collateralTokenCount)")
                    return TidalProtocolUtils.uint256ToUFix64(availableTokens + collateralTokenCount, decimals: TidalProtocolUtils.decimals)
                }
            }

            // At this point, we're either dealing with a position that didn't have a credit balance in the withdraw
            // token, or we've accounted for the credit balance and adjusted the effective collateral above.

            // We can calculate the available debt increase that would bring us to the target health
            var availableDebtIncrease = TidalProtocolUtils.div(effectiveCollateralAfterDeposit, uintTargetHealth) - effectiveDebtAfterDeposit
            let availableTokens = TidalProtocolUtils.div(TidalProtocolUtils.mul(availableDebtIncrease, uintWithdrawBorrowFactor), uintWithdrawPrice)
            log("    [CONTRACT] availableDebtIncrease: \(availableDebtIncrease)")
            log("    [CONTRACT] availableTokens: \(availableTokens)")
            log("    [CONTRACT] availableTokens + collateralTokenCount: \(availableTokens + collateralTokenCount)")
            return TidalProtocolUtils.uint256ToUFix64(availableTokens + collateralTokenCount, decimals: TidalProtocolUtils.decimals)
        }

        /// Returns the position's health if the given amount of the specified token were deposited
        access(all) fun healthAfterDeposit(pid: UInt64, type: Type, amount: UFix64): UInt256 {
            let balanceSheet = self._getUpdatedBalanceSheet(pid: pid)
            let position = self._borrowPosition(pid: pid)
            let tokenState = self._borrowUpdatedTokenState(type: type)

            var effectiveCollateralIncrease: UInt256 = 0
            var effectiveDebtDecrease: UInt256 = 0

            let uintAmount = TidalProtocolUtils.ufix64ToUInt256(amount, decimals: TidalProtocolUtils.decimals)
            let uintPrice = TidalProtocolUtils.ufix64ToUInt256(self.priceOracle.price(ofToken: type)!, decimals: TidalProtocolUtils.decimals)
            let uintCollateralFactor = TidalProtocolUtils.ufix64ToUInt256(self.collateralFactor[type]!, decimals: TidalProtocolUtils.decimals)
            let uintBorrowFactor = TidalProtocolUtils.ufix64ToUInt256(self.borrowFactor[type]!, decimals: TidalProtocolUtils.decimals)
            if position.balances[type] == nil || position.balances[type]!.direction == BalanceDirection.Credit {
                // Since the user has no debt in the given token, we can just compute how much
                // additional collateral this deposit will create.
                effectiveCollateralIncrease = TidalProtocolUtils.mul(
                    TidalProtocolUtils.mul(uintAmount, uintPrice),
                    uintCollateralFactor
                )
            } else {
                // The user has a debit position in the given token, we need to figure out if this deposit
                // will only pay off some of the debt, or if it will also create new collateral.
                let debtBalance = position.balances[type]!.scaledBalance
                let trueDebt = TidalProtocol.scaledBalanceToTrueBalance(debtBalance,
                    interestIndex: tokenState.debitInterestIndex
                )

                if trueDebt >= uintAmount {
                    // This deposit will wipe out some or all of the debt, but won't create new collateral, we
                    // just need to account for the debt decrease.
                    effectiveDebtDecrease = TidalProtocolUtils.div(
                        TidalProtocolUtils.mul(uintAmount, uintPrice),
                        uintBorrowFactor
                    )
                } else {
                    // This deposit will wipe out all of the debt, and create new collateral.
                    effectiveCollateralIncrease = TidalProtocolUtils.mul(
                        TidalProtocolUtils.mul(uintAmount - trueDebt, uintPrice),
                        uintCollateralFactor
                    )
                }
            }

            return TidalProtocol.healthComputation(
                effectiveCollateral: balanceSheet.effectiveCollateral + effectiveCollateralIncrease,
                effectiveDebt: balanceSheet.effectiveDebt - effectiveDebtDecrease
            )
        }

        // Returns health value of this position if the given amount of the specified token were withdrawn without
        // using the top up source.
        // NOTE: This method can return health values below 1.0, which aren't actually allowed. This indicates
        // that the proposed withdrawal would fail (unless a top up source is available and used).
        access(all) fun healthAfterWithdrawal(pid: UInt64, type: Type, amount: UFix64): UInt256 {
            let balanceSheet = self._getUpdatedBalanceSheet(pid: pid)
            let position = self._borrowPosition(pid: pid)
            let tokenState = self._borrowUpdatedTokenState(type: type)

            var effectiveCollateralDecrease: UInt256 = 0
            var effectiveDebtIncrease: UInt256 = 0

            let uintAmount = TidalProtocolUtils.ufix64ToUInt256(amount, decimals: TidalProtocolUtils.decimals)
            let uintPrice = TidalProtocolUtils.ufix64ToUInt256(self.priceOracle.price(ofToken: type)!, decimals: TidalProtocolUtils.decimals)
            let uintCollateralFactor = TidalProtocolUtils.ufix64ToUInt256(self.collateralFactor[type]!, decimals: TidalProtocolUtils.decimals)
            let uintBorrowFactor = TidalProtocolUtils.ufix64ToUInt256(self.borrowFactor[type]!, decimals: TidalProtocolUtils.decimals)
            if position.balances[type] == nil || position.balances[type]!.direction == BalanceDirection.Debit {
                // The user has no credit position in the given token, we can just compute how much
                // additional effective debt this withdrawal will create.
                effectiveDebtIncrease = TidalProtocolUtils.div(
                    TidalProtocolUtils.mul(uintAmount, uintPrice),
                    uintBorrowFactor
                )
            } else {
                // The user has a credit position in the given token, we need to figure out if this withdrawal
                // will only draw down some of the collateral, or if it will also create new debt.
                let creditBalance = position.balances[type]!.scaledBalance
                let trueCredit = TidalProtocol.scaledBalanceToTrueBalance(creditBalance,
                    interestIndex: tokenState.creditInterestIndex
                )

                if trueCredit >= uintAmount {
                    // This withdrawal will draw down some collateral, but won't create new debt, we
                    // just need to account for the collateral decrease.
                    // effectiveCollateralDecrease = amount * self.priceOracle.price(ofToken: type)! * self.collateralFactor[type]!
                    effectiveCollateralDecrease = TidalProtocolUtils.mul(
                        TidalProtocolUtils.mul(uintAmount, uintPrice),
                        uintCollateralFactor
                    )
                } else {
                    // The withdrawal will wipe out all of the collateral, and create new debt.
                    effectiveDebtIncrease = TidalProtocolUtils.div(
                        TidalProtocolUtils.mul(uintAmount - trueCredit, uintPrice),
                        uintBorrowFactor
                    )
                    effectiveCollateralDecrease = TidalProtocolUtils.mul(
                        TidalProtocolUtils.mul(trueCredit, uintPrice),
                        uintCollateralFactor
                    )
                }
            }

            return TidalProtocol.healthComputation(
                effectiveCollateral: balanceSheet.effectiveCollateral - effectiveCollateralDecrease,
                effectiveDebt: balanceSheet.effectiveDebt + effectiveDebtIncrease
            )
        }

        ///////////////////////////
        // POSITION MANAGEMENT
        ///////////////////////////

        /// Creates a lending position against the provided collateral funds, depositing the loaned amount to the
        /// given Sink. If a Source is provided, the position will be configured to pull loan repayment when the loan
        /// becomes undercollateralized, preferring repayment to outright liquidation.
        access(all) fun createPosition(
            funds: @{FungibleToken.Vault},
            issuanceSink: {DFB.Sink},
            repaymentSource: {DFB.Source}?,
            pushToDrawDownSink: Bool
        ): UInt64 {
            pre {
                self.globalLedger[funds.getType()] != nil: "Invalid token type \(funds.getType().identifier) - not supported by this Pool"
            }
            // construct a new InternalPosition, assigning it the current position ID
            let id = self.nextPositionID
            self.nextPositionID = self.nextPositionID + 1
            self.positions[id] <-! create InternalPosition()

            emit Opened(pid: id, poolUUID: self.uuid)

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

        /// Allows anyone to deposit funds into any position. If the provided Vault is not supported by the Pool, the
        /// operation reverts.
        access(all) fun depositToPosition(pid: UInt64, from: @{FungibleToken.Vault}) {
            self.depositAndPush(pid: pid, from: <-from, pushToDrawDownSink: false)
        }

        /// Deposits the provided funds to the specified position with the configurable `pushToDrawDownSink` option. If
        /// `pushToDrawDownSink` is true, excess value putting the position above its max health is pushed to the
        /// position's configured `drawDownSink`.
        access(EPosition) fun depositAndPush(pid: UInt64, from: @{FungibleToken.Vault}, pushToDrawDownSink: Bool) {
            pre {
                self.positions[pid] != nil: "Invalid position ID \(pid) - could not find an InternalPosition with the requested ID in the Pool"
                self.globalLedger[from.getType()] != nil: "Invalid token type \(from.getType().identifier) - not supported by this Pool"
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

            // Update time-based state
            // REMOVED: This is now handled by tokenState() helper function
            // tokenState.updateForTimeChange()

            // Deposit rate limiting
            let depositAmount = from.balance
            let uintDepositAmount = TidalProtocolUtils.ufix64ToUInt256(depositAmount, decimals: TidalProtocolUtils.decimals)
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

            // If this position doesn't currently have an entry for this token, create one.
            if position.balances[type] == nil {
                position.balances[type] = InternalBalance()
            }

            // CHANGE: Create vault if it doesn't exist yet
            if self.reserves[type] == nil {
                self.reserves[type] <-! from.createEmptyVault()
            }
            let reserveVault = (&self.reserves[type] as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?)!

            // Reflect the deposit in the position's balance
            position.balances[type]!.recordDeposit(amount: uintDepositAmount, tokenState: tokenState)

            // Add the money to the reserves
            reserveVault.deposit(from: <-from)

            // Rebalancing and queue management
            if pushToDrawDownSink {
                self.rebalancePosition(pid: pid, force: true)
            }

            self._queuePositionForUpdateIfNecessary(pid: pid)
            emit Deposited(pid: pid, poolUUID: self.uuid, type: type.identifier, amount: amount, depositedUUID: depositedUUID)
        }

        /// Withdraws the requested funds from the specified position. Callers should be careful that the withdrawal
        /// does not put their position under its target health, especially if the position doesn't have a configured
        /// `topUpSource` from which to repay borrowed funds in the event of undercollaterlization.
        access(EPosition) fun withdraw(pid: UInt64, amount: UFix64, type: Type): @{FungibleToken.Vault} {
            // Call the enhanced function with pullFromTopUpSource = false for backward compatibility
            return <- self.withdrawAndPull(pid: pid, type: type, amount: amount, pullFromTopUpSource: false)
        }

        /// Withdraws the requested funds from the specified position with the configurable `pullFromTopUpSource`
        /// option. If `pullFromTopUpSource` is true, deficient value putting the position below its min health is
        /// pulled from the position's configured `topUpSource`.
        access(EPosition) fun withdrawAndPull(
            pid: UInt64,
            type: Type,
            amount: UFix64,
            pullFromTopUpSource: Bool
        ): @{FungibleToken.Vault} {
            pre {
                self.positions[pid] != nil: "Invalid position ID \(pid) - could not find an InternalPosition with the requested ID in the Pool"
                self.globalLedger[type] != nil: "Invalid token type \(type.identifier) - not supported by this Pool"
            }
            if amount == 0.0 {
                return <- DFBUtils.getEmptyVault(type)
            }

            // Get a reference to the user's position and global token state for the affected token.
            let position = self._borrowPosition(pid: pid)
            let tokenState = self._borrowUpdatedTokenState(type: type)

            // Update the global interest indices on the affected token to reflect the passage of time.
            // REMOVED: This is now handled by tokenState() helper function
            // tokenState.updateForTimeChange()

            // Preflight to see if the funds are available
            let topUpSource = position.topUpSource as auth(FungibleToken.Withdraw) &{DFB.Source}?
            let topUpType = topUpSource?.getSourceType() ?? self.defaultToken

            let requiredDeposit = self.fundsRequiredForTargetHealthAfterWithdrawing(
                pid: pid,
                depositType: topUpType,
                targetHealth: position.minHealth,
                withdrawType: type,
                withdrawAmount: amount
            )

            var canWithdraw = false

            if requiredDeposit == 0.0 {
                // We can service this withdrawal without any top up
                canWithdraw = true
            } else {
                // We need more funds to service this withdrawal, see if they are available from the top up source
                if pullFromTopUpSource && topUpSource != nil {
                    // If we have to rebalance, let's try to rebalance to the target health, not just the minimum
                    let idealDeposit = self.fundsRequiredForTargetHealthAfterWithdrawing(
                        pid: pid,
                        depositType: topUpType,
                        targetHealth: position.targetHealth,
                        withdrawType: type,
                        withdrawAmount: amount
                    )

                    let pulledVault <- topUpSource!.withdrawAvailable(maxAmount: idealDeposit)

                    // NOTE: We requested the "ideal" deposit, but we compare against the required deposit here.
                    // The top up source may not have enough funds get us to the target health, but could have
                    // enough to keep us over the minimum.
                    if pulledVault.balance >= requiredDeposit {
                        // We can service this withdrawal if we deposit funds from our top up source
                        self.depositAndPush(pid: pid, from: <-pulledVault, pushToDrawDownSink: false)
                        canWithdraw = true
                    } else {
                        // We can't get the funds required to service this withdrawal, so we need to redeposit what we got
                        self.depositAndPush(pid: pid, from: <-pulledVault, pushToDrawDownSink: false)
                    }
                }
            }

            if !canWithdraw {
                // Log detailed information about the failed withdrawal
                let availableBalance = self.availableBalance(pid: pid, type: type, pullFromTopUpSource: false)
                log("    [CONTRACT] WITHDRAWAL FAILED:")
                log("    [CONTRACT] Position ID: \(pid)")
                log("    [CONTRACT] Token type: \(type.identifier)")
                log("    [CONTRACT] Requested amount: \(amount)")
                log("    [CONTRACT] Available balance (without topUp): \(availableBalance)")
                log("    [CONTRACT] Required deposit for minHealth: \(requiredDeposit)")
                log("    [CONTRACT] Pull from topUpSource: \(pullFromTopUpSource)")
                
                // We can't service this withdrawal, so we just abort
                panic("Cannot withdraw \(amount) of \(type.identifier) from position ID \(pid) - Insufficient funds for withdrawal")
            }

            // If this position doesn't currently have an entry for this token, create one.
            if position.balances[type] == nil {
                position.balances[type] = InternalBalance()
            }

            let reserveVault = (&self.reserves[type] as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?)!

            // Reflect the withdrawal in the position's balance
            let uintAmount = TidalProtocolUtils.ufix64ToUInt256(amount, decimals: TidalProtocolUtils.decimals)
            position.balances[type]!.recordWithdrawal(amount: uintAmount, tokenState: tokenState)
            log(self.positionHealth(pid: pid))
            if self.positionHealth(pid: pid) != 0 {
                // Ensure that this withdrawal doesn't cause the position to be overdrawn.
                assert(position.intMinHealth() <= self.positionHealth(pid: pid), message: "Position is overdrawn")
            }

            // Queue for update if necessary
            self._queuePositionForUpdateIfNecessary(pid: pid)

            let withdrawn <- reserveVault.withdraw(amount: amount)

            emit Withdrawn(pid: pid, poolUUID: self.uuid, type: type.identifier, amount: withdrawn.balance, withdrawnUUID: withdrawn.uuid)

            return <- withdrawn
        }

        /// Sets the InternalPosition's drawDownSink. If `nil`, the Pool will not be able to push overflown value when
        /// the position exceeds its maximum health. Note, if a non-nil value is provided, the Sink MUST accept the
        /// Pool's default deposits or the operation will revert.
        access(EPosition) fun provideDrawDownSink(pid: UInt64, sink: {DFB.Sink}?) {
            let position = self._borrowPosition(pid: pid)
            position.setDrawDownSink(sink)
        }

        /// Sets the InternalPosition's topUpSource. If `nil`, the Pool will not be able to pull underflown value when
        /// the position falls below its minimum health which may result in liquidation.
        access(EPosition) fun provideTopUpSource(pid: UInt64, source: {DFB.Source}?) {
            let position = self._borrowPosition(pid: pid)
            position.setTopUpSource(source)
        }

        ///////////////////////
        // POOL MANAGEMENT
        ///////////////////////

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
                self.globalLedger[tokenType] == nil: "Token type already supported"
                tokenType.isSubtype(of: Type<@{FungibleToken.Vault}>()):
                "Invalid token type \(tokenType.identifier) - tokenType must be a FungibleToken Vault implementation"
                collateralFactor > 0.0 && collateralFactor <= 1.0: "Collateral factor must be between 0 and 1"
                borrowFactor > 0.0 && borrowFactor <= 1.0: "Borrow factor must be between 0 and 1"
                depositRate > 0.0: "Deposit rate must be positive"
                depositCapacityCap > 0.0: "Deposit capacity cap must be positive"
                DFBUtils.definingContractIsFungibleToken(tokenType):
                "Invalid token contract definition for tokenType \(tokenType.identifier) - defining contract is not FungibleToken conformant"
            }

            // Add token to global ledger with its interest curve and deposit parameters
            self.globalLedger[tokenType] = TokenState(
                interestCurve: interestCurve,
                depositRate: depositRate,
                depositCapacityCap: depositCapacityCap
            )

            // Set collateral factor (what percentage of value can be used as collateral)
            self.collateralFactor[tokenType] = collateralFactor

            // Set borrow factor (risk adjustment for borrowed amounts)
            self.borrowFactor[tokenType] = borrowFactor
        }

        /// Rebalances the position to the target health value. If `force` is `true`, the position will be rebalanced
        /// even if it is currently healthy. Otherwise, this function will do nothing if the position is within the
        /// min/max health bounds.
        access(EPosition) fun rebalancePosition(pid: UInt64, force: Bool) {
            let position = self._borrowPosition(pid: pid)
            let balanceSheet = self._getUpdatedBalanceSheet(pid: pid)

            if !force && (position.intMinHealth() <= balanceSheet.health  && balanceSheet.health <= position.intMaxHealth()) {
                // We aren't forcing the update, and the position is already between its desired min and max. Nothing to do!
                return
            }

            if balanceSheet.health < position.intTargetHealth() {
                // The position is undercollateralized, see if the source can get more collateral to bring it up to the target health.
                if position.topUpSource != nil {
                    let topUpSource = position.topUpSource! as auth(FungibleToken.Withdraw) &{DFB.Source}
                    let idealDeposit = self.fundsRequiredForTargetHealth(
                        pid: pid,
                        type: topUpSource.getSourceType(),
                        targetHealth: position.targetHealth
                    )
					log("    [CONTRACT] idealDeposit: \(idealDeposit)")

                    let pulledVault <- topUpSource.withdrawAvailable(maxAmount: idealDeposit)

                    emit Rebalanced(pid: pid, poolUUID: self.uuid, atHealth: balanceSheet.health, amount: pulledVault.balance, fromUnder: true)

                    self.depositAndPush(pid: pid, from: <-pulledVault, pushToDrawDownSink: false)
                }
            } else if balanceSheet.health > position.intTargetHealth() {
                // The position is overcollateralized, we'll withdraw funds to match the target health and offer it to the sink.
                if position.drawDownSink != nil {
                    let drawDownSink = position.drawDownSink!
                    let sinkType = drawDownSink.getSinkType()
                    let idealWithdrawal = self.fundsAvailableAboveTargetHealth(
                        pid: pid,
                        type: sinkType,
                        targetHealth: position.targetHealth
                    )
					log("    [CONTRACT] idealWithdrawal: \(idealWithdrawal)")

                    // Compute how many tokens of the sink's type are available to hit our target health.
                    let sinkCapacity = drawDownSink.minimumCapacity()
                    let sinkAmount = (idealWithdrawal > sinkCapacity) ? sinkCapacity : idealWithdrawal

                    if sinkAmount > 0.0 && sinkType == self.defaultToken { // second conditional included for sake of tracer bullet
                        // BUG: Calling through to withdrawAndPull results in an insufficient funds from the position's
                        //      topUpSource. These funds should come from the protocol or reserves, not from the user's
                        //      funds. To unblock here, we just mint MOET when a position is overcollateralized
                        // let sinkVault <- self.withdrawAndPull(
                        //     pid: pid,
                        //     type: sinkType,
                        //     amount: sinkAmount,
                        //     pullFromTopUpSource: false
                        // )

                        let tokenState = self._borrowUpdatedTokenState(type: self.defaultToken)
                        if position.balances[self.defaultToken] == nil {
                            position.balances[self.defaultToken] = InternalBalance()
                        }
                        // record the withdrawal and mint the tokens
                        let uintSinkAmount = TidalProtocolUtils.ufix64ToUInt256(sinkAmount, decimals: TidalProtocolUtils.decimals)
                        position.balances[self.defaultToken]!.recordWithdrawal(amount: uintSinkAmount, tokenState: tokenState)
                        let sinkVault <- TidalProtocol._borrowMOETMinter().mintTokens(amount: sinkAmount)

                        emit Rebalanced(pid: pid, poolUUID: self.uuid, atHealth: balanceSheet.health, amount: sinkVault.balance, fromUnder: false)

                        // Push what we can into the sink, and redeposit the rest
                        drawDownSink.depositCapacity(from: &sinkVault as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
                        if sinkVault.balance > 0.0 {
                            self.depositAndPush(pid: pid, from: <-sinkVault, pushToDrawDownSink: false)
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
                    self.depositAndPush(pid: pid, from: <-queuedVault, pushToDrawDownSink: false)
                } else {
                    // We can only deposit part of the queued deposit, so do that and leave the rest in the queue
                    // for the next time we run.
                    let depositVault <- queuedVault.withdraw(amount: maxDeposit)
                    self.depositAndPush(pid: pid, from: <-depositVault, pushToDrawDownSink: false)

                    // We need to update the queued vault to reflect the amount we used up
                    position.queuedDeposits[depositType] <-! queuedVault
                }
            }

            // Now that we've deposited a non-zero amount of any queued deposits, we can rebalance
            // the position if necessary.
            self.rebalancePosition(pid: pid, force: false)
        }

        ////////////////
        // INTERNAL
        ////////////////

        /// Queues a position for asynchronous updates if the position has been marked as requiring an update
        access(self) fun _queuePositionForUpdateIfNecessary(pid: UInt64) {
            if self.positionsNeedingUpdates.contains(pid) {
                // If this position is already queued for an update, no need to check anything else
                return
            } else {
                // If this position is not already queued for an update, we need to check if it needs one
                let position = self._borrowPosition(pid: pid)

                if position.queuedDeposits.length > 0 {
                    // This position has deposits that need to be processed, so we need to queue it for an update
                    self.positionsNeedingUpdates.append(pid)
                    return
                }

                let positionHealth = self.positionHealth(pid: pid)

                if positionHealth < position.intMinHealth() || positionHealth > position.intMaxHealth() {
                    // This position is outside the configured health bounds, we queue it for an update
                    self.positionsNeedingUpdates.append(pid)
                    return
                }
            }
        }

        /// Returns a position's BalanceSheet containing its effective collateral and debt as well as its current health
        access(self) fun _getUpdatedBalanceSheet(pid: UInt64): BalanceSheet {
            let position = self._borrowPosition(pid: pid)
            let priceOracle = &self.priceOracle as &{DFB.PriceOracle}

            // Get the position's collateral and debt values in terms of the default token.
            var effectiveCollateral: UInt256 = 0
            var effectiveDebt: UInt256 = 0

            for type in position.balances.keys {
                let balance = position.balances[type]!
                let tokenState = self._borrowUpdatedTokenState(type: type)
                if balance.direction == BalanceDirection.Credit {
                    let trueBalance = TidalProtocol.scaledBalanceToTrueBalance(balance.scaledBalance,
                        interestIndex: tokenState.creditInterestIndex)

                    let convertedPrice = TidalProtocolUtils.ufix64ToUInt256(priceOracle.price(ofToken: type)!, decimals: TidalProtocolUtils.decimals)
                    let value = TidalProtocolUtils.mul(convertedPrice, trueBalance)

                    let convertedCollateralFactor = TidalProtocolUtils.ufix64ToUInt256(self.collateralFactor[type]!, decimals: TidalProtocolUtils.decimals)
                    effectiveCollateral = effectiveCollateral + TidalProtocolUtils.mul(value, convertedCollateralFactor)
                } else {
                    let trueBalance = TidalProtocol.scaledBalanceToTrueBalance(balance.scaledBalance,
                        interestIndex: tokenState.debitInterestIndex)

                    let convertedPrice = TidalProtocolUtils.ufix64ToUInt256(priceOracle.price(ofToken: type)!, decimals: TidalProtocolUtils.decimals)
                    let value = TidalProtocolUtils.mul(convertedPrice, trueBalance)

                    let convertedBorrowFactor = TidalProtocolUtils.ufix64ToUInt256(self.borrowFactor[type]!, decimals: TidalProtocolUtils.decimals)
                    effectiveDebt = effectiveDebt + TidalProtocolUtils.div(value, convertedBorrowFactor)
                }
            }

            return BalanceSheet(effectiveCollateral: effectiveCollateral, effectiveDebt: effectiveDebt)
        }

        /// A convenience function that returns a reference to a particular token state, making sure it's up-to-date for
        /// the passage of time. This should always be used when accessing a token state to avoid missing interest
        /// updates (duplicate calls to updateForTimeChange() are a nop within a single block).
        access(self) fun _borrowUpdatedTokenState(type: Type): auth(EImplementation) &TokenState {
            let state = &self.globalLedger[type]! as auth(EImplementation) &TokenState
            state.updateForTimeChange()
            return state
        }

        /// Returns an authorized reference to the requested InternalPosition or `nil` if the position does not exist
        access(self) view fun _borrowPosition(pid: UInt64): auth(EImplementation) &InternalPosition {
            return &self.positions[pid] as auth(EImplementation) &InternalPosition?
                ?? panic("Invalid position ID \(pid) - could not find an InternalPosition with the requested ID in the Pool")
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
        access(all) fun createPool(defaultToken: Type, priceOracle: {DFB.PriceOracle}) {
            pre {
                TidalProtocol.account.storage.type(at: TidalProtocol.PoolStoragePath) == nil:
                "Storage collision - Pool has already been created & saved to \(TidalProtocol.PoolStoragePath)"
            }
            let pool <- create Pool(defaultToken: defaultToken, priceOracle: priceOracle)
            TidalProtocol.account.storage.save(<-pool, to: TidalProtocol.PoolStoragePath)
            let cap = TidalProtocol.account.capabilities.storage.issue<&Pool>(TidalProtocol.PoolStoragePath)
            TidalProtocol.account.capabilities.unpublish(TidalProtocol.PoolPublicPath)
            TidalProtocol.account.capabilities.publish(cap, at: TidalProtocol.PoolPublicPath)
        }
    }

    /// Position
    ///
    /// A Position is an external object representing ownership of value deposited to the protocol. From a Position, an
    /// actor can deposit and withdraw funds as well as construct DeFiBlocks components enabling value flows in and out
    /// of the Position from within the context of DeFiBlocks stacks.
    ///
    // TODO: Consider making this a resource given how critical it is to accessing a loan
    access(all) struct Position {
        /// The unique ID of the Position used to track deposits and withdrawals to the Pool
        access(self) let id: UInt64
        /// An authorized Capability to which the Position was opened
        access(self) let pool: Capability<auth(EPosition) &Pool>

        init(id: UInt64, pool: Capability<auth(EPosition) &Pool>) {
            pre {
                pool.check(): "Invalid Pool Capability provided - cannot construct Position"
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
        access(all) fun getHealth(): UInt256 {
            let pool = self.pool.borrow()!
            return pool.positionHealth(pid: self.id)
        }
        /// Returns the Position's target health
        access(all) fun getTargetHealth(): UFix64 {
            return 0.0 // TODO
        }
        /// Sets the target health of the Position
        access(all) fun setTargetHealth(targetHealth: UFix64) {
            // TODO
        }
        /// Returns the minimum health of the Position
        access(all) fun getMinHealth(): UFix64 {
            return 0.0 // TODO
        }
        /// Sets the minimum health of the Position
        access(all) fun setMinHealth(minHealth: UFix64) {
            // TODO
        }
        /// Returns the maximum health of the Position
        access(all) fun getMaxHealth(): UFix64 {
            // TODO
            return 0.0
        }
        /// Sets the maximum health of the position
        access(all) fun setMaxHealth(maxHealth: UFix64) {
            // TODO
        }
        /// Returns the maximum amount of the given token type that could be deposited into this position
        access(all) fun getDepositCapacity(type: Type): UFix64 {
            // There's no limit on deposits from the position's perspective
            return UFix64.max
        }
        /// Deposits funds to the Position without pushing to the drawDownSink if the deposit puts the Position above
        /// its maximum health
        access(all) fun deposit(from: @{FungibleToken.Vault}) {
            let pool = self.pool.borrow()!
            pool.depositAndPush(pid: self.id, from: <-from, pushToDrawDownSink: false)
        }
        /// Deposits funds to the Position enabling the caller to configure whether excess value should be pushed to the
        /// drawDownSink if the deposit puts the Position above its maximum health
        access(all) fun depositAndPush(from: @{FungibleToken.Vault}, pushToDrawDownSink: Bool) {
            let pool = self.pool.borrow()!
            pool.depositAndPush(pid: self.id, from: <-from, pushToDrawDownSink: pushToDrawDownSink)
        }
        /// Withdraws funds from the Position without pulling from the topUpSource if the deposit puts the Position below
        /// its minimum health
        access(FungibleToken.Withdraw) fun withdraw(type: Type, amount: UFix64): @{FungibleToken.Vault} {
            return <- self.withdrawAndPull(type: type, amount: amount, pullFromTopUpSource: false)
        }
        /// Withdraws funds from the Position enabling the caller to configure whether insufficient value should be
        /// pulled from the topUpSource if the deposit puts the Position below its minimum health
        access(FungibleToken.Withdraw) fun withdrawAndPull(type: Type, amount: UFix64, pullFromTopUpSource: Bool): @{FungibleToken.Vault} {
            let pool = self.pool.borrow()!
            return <- pool.withdrawAndPull(pid: self.id, type: type, amount: amount, pullFromTopUpSource: pullFromTopUpSource)
        }
        /// Returns a new Sink for the given token type that will accept deposits of that token and update the
        /// position's collateral and/or debt accordingly. Note that calling this method multiple times will create
        /// multiple sinks, each of which will continue to work regardless of how many other sinks have been created.
        access(all) fun createSink(type: Type): {DFB.Sink} {
            // create enhanced sink with pushToDrawDownSink option
            return self.createSinkWithOptions(type: type, pushToDrawDownSink: false)
        }
        /// Returns a new Sink for the given token type and pushToDrawDownSink opetion that will accept deposits of that
        /// token and update the position's collateral and/or debt accordingly. Note that calling this method multiple
        /// times will create multiple sinks, each of which will continue to work regardless of how many other sinks
        /// have been created.
        access(all) fun createSinkWithOptions(type: Type, pushToDrawDownSink: Bool): {DFB.Sink} {
            let pool = self.pool.borrow()!
            return PositionSink(id: self.id, pool: self.pool, type: type, pushToDrawDownSink: pushToDrawDownSink)
        }
        /// Returns a new Source for the given token type that will service withdrawals of that token and update the
        /// position's collateral and/or debt accordingly. Note that calling this method multiple times will create
        /// multiple sources, each of which will continue to work regardless of how many other sources have been created.
        access(FungibleToken.Withdraw) fun createSource(type: Type): {DFB.Source} {
            // Create enhanced source with pullFromTopUpSource = true
            return self.createSourceWithOptions(type: type, pullFromTopUpSource: false)
        }
        /// Returns a new Source for the given token type and pullFromTopUpSource option that will service withdrawals
        /// of that token and update the position's collateral and/or debt accordingly. Note that calling this method
        /// multiple times will create multiple sources, each of which will continue to work regardless of how many
        /// other sources have been created.
        access(FungibleToken.Withdraw) fun createSourceWithOptions(type: Type, pullFromTopUpSource: Bool): {DFB.Source} {
            let pool = self.pool.borrow()!
            return PositionSource(id: self.id, pool: self.pool, type: type, pullFromTopUpSource: pullFromTopUpSource)
        }
        /// Provides a sink to the Position that will have tokens proactively pushed into it when the position has
        /// excess collateral. (Remember that sinks do NOT have to accept all tokens provided to them; the sink can
        /// choose to accept only some (or none) of the tokens provided, leaving the position overcollateralized).
        ///
        /// Each position can have only one sink, and the sink must accept the default token type configured for the
        /// pool. Providing a new sink will replace the existing sink. Pass nil to configure the position to not push
        /// tokens when the Position exceeds its maximum health.
        access(FungibleToken.Withdraw) fun provideSink(sink: {DFB.Sink}?) {
            let pool = self.pool.borrow()!
            pool.provideDrawDownSink(pid: self.id, sink: sink)
        }
        /// Provides a source to the Position that will have tokens proactively pulled from it when the position has
        /// insufficient collateral. If the source can cover the position's debt, the position will not be liquidated.
        ///
        /// Each position can have only one source, and the source must accept the default token type configured for the
        /// pool. Providing a new source will replace the existing source. Pass nil to configure the position to not
        /// pull tokens.
        access(all) fun provideSource(source: {DFB.Source}?) {
            let pool = self.pool.borrow()!
            pool.provideTopUpSource(pid: self.id, source: source)
        }
    }

    /// PositionSink
    ///
    /// A DeFiBlocks connector enabling deposits to a Position from within a DeFiBlocks stack. This Sink is intended to
    /// be constructed from a Position object.
    access(all) struct PositionSink: DFB.Sink {
        /// An optional DFB.UniqueIdentifier that identifies this Sink with the DeFiBlocks stack its a part of
        access(contract) let uniqueID: DFB.UniqueIdentifier?
        /// An authorized Capability on the Pool for which the related Position is in
        access(self) let pool: Capability<auth(EPosition) &Pool>
        /// The ID of the position in the Pool
        access(self) let positionID: UInt64
        /// The Type of Vault this Sink accepts
        access(self) let type: Type
        /// Whether deposits through this Sink to the Position should push available value to the Position's
        /// drawDownSink
        access(self) let pushToDrawDownSink: Bool

        init(id: UInt64, pool: Capability<auth(EPosition) &Pool>, type: Type, pushToDrawDownSink: Bool) {
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
    }

    /// PositionSource
    ///
    /// A DeFiBlocks connector enabling withdrawals from a Position from within a DeFiBlocks stack. This Source is
    /// intended to be constructed from a Position object.
    ///
    access(all) struct PositionSource: DFB.Source {
        /// An optional DFB.UniqueIdentifier that identifies this Sink with the DeFiBlocks stack its a part of
        access(contract) let uniqueID: DFB.UniqueIdentifier?
        /// An authorized Capability on the Pool for which the related Position is in
        access(self) let pool: Capability<auth(EPosition) &Pool>
        /// The ID of the position in the Pool
        access(self) let positionID: UInt64
        /// The Type of Vault this Sink provides
        access(self) let type: Type
        /// Whether withdrawals through this Sink from the Position should pull value from the Position's topUpSource
        /// in the event the withdrawal puts the position under its target health
        access(self) let pullFromTopUpSource: Bool

        init(id: UInt64, pool: Capability<auth(EPosition) &Pool>, type: Type, pullFromTopUpSource: Bool) {
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
        /// Returns the minimum availble this Source can provide on withdrawal
        access(all) fun minimumAvailable(): UFix64 {
            if !self.pool.check() {
                return 0.0
            }
            let pool = self.pool.borrow()!
            return pool.availableBalance(pid: self.positionID, type: self.type, pullFromTopUpSource: self.pullFromTopUpSource)
        }
        /// Withdraws up to the max amount as the sourceType Vault
        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            if !self.pool.check() {
                return <- DFBUtils.getEmptyVault(self.type)
            }
            let pool = self.pool.borrow()!
            let available = pool.availableBalance(pid: self.positionID, type: self.type, pullFromTopUpSource: self.pullFromTopUpSource)
            let withdrawAmount = (available > maxAmount) ? maxAmount : available
            if withdrawAmount > 0.0 {
                return <- pool.withdrawAndPull(pid: self.positionID, type: self.type, amount: withdrawAmount, pullFromTopUpSource: self.pullFromTopUpSource)
            } else {
                // Create an empty vault - this is a limitation we need to handle properly
                return <- DFBUtils.getEmptyVault(self.type)
            }
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

        init(vaultType: Type, direction: BalanceDirection, balance: UFix64) {
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
        access(all) let health: UInt256

        init(balances: [PositionBalance], poolDefaultToken: Type, defaultTokenAvailableBalance: UFix64, health: UInt256) {
            self.balances = balances
            self.poolDefaultToken = poolDefaultToken
            self.defaultTokenAvailableBalance = defaultTokenAvailableBalance
            self.health = health
        }
    }

    /* --- PUBLIC METHODS ---- */

    /// Takes out a TidalProtocol loan with the provided collateral, returning a Position that can be used to manage
    /// collateral and borrowed fund flows
    ///
    /// @param collateral: The collateral used as the basis for a loan. Only certain collateral types are supported, so
    ///     callers should be sure to check the provided Vault is supported to prevent reversion.
    /// @param issuanceSink: The DeFiBlocks Sink connector where the protocol will deposit borrowed funds. If the
    ///     position becomes overcollateralized, additional funds will be borrowed (to maintain target LTV) and
    ///     deposited to the provided Sink.
    /// @param repaymentSource: An optional DeFiBlocks Source connector from which the protocol will attempt to source
    ///     borrowed funds in the event of undercollateralization prior to liquidating. If none is provided, the
    ///     position health will not be actively managed on the down side, meaning liquidation is possible as soon as
    ///     the loan becomes undercollateralized.
    ///
    /// @return the Position via which the caller can manage their position
    ///
    access(all) fun openPosition(
        collateral: @{FungibleToken.Vault},
        issuanceSink: {DFB.Sink},
        repaymentSource: {DFB.Source}?,
        pushToDrawDownSink: Bool
    ): Position {
        let pid = self._borrowPool().createPosition(
                funds: <-collateral,
                issuanceSink: issuanceSink,
                repaymentSource: repaymentSource,
                pushToDrawDownSink: pushToDrawDownSink
            )
        let cap = self.account.capabilities.storage.issue<auth(EPosition) &Pool>(self.PoolStoragePath)
        return Position(id: pid, pool: cap)
    }

    /// Returns a health value computed from the provided effective collateral and debt values where health is a ratio
    /// of effective collateral over effective debt
    access(all) view fun healthComputation(effectiveCollateral: UInt256, effectiveDebt: UInt256): UInt256 {
        if effectiveCollateral == 0 {
            return 0
        } else if effectiveDebt == 0 || TidalProtocolUtils.div(effectiveDebt, effectiveCollateral) == 0 {
            // If debt is so small relative to collateral that division rounds to zero,
            // the health is essentially infinite
            return UInt256.max
        }
        // TODO: return this value after refactoring health to UInt256
        return TidalProtocolUtils.div(effectiveCollateral, effectiveDebt)
    }

    /// A multiplication function for interest calculations. It assumes that both values are very close to 1 and
    /// represent fixed point numbers with 18 decimal places of precision.
    access(all) view fun interestMul(_ a: UInt256, _ b: UInt256): UInt256 {
        // For 18-decimal precision, we need to divide by e9
        // This is because: (a/1e9) * (b/1e9) = (a*b)/1e18
        let aScaled = a / TidalProtocolUtils.e9
        let bScaled = b / TidalProtocolUtils.e9

        return aScaled * bScaled
    }

    // Converts a yearly interest rate to a per-second multiplication factor (stored in a UInt256 as a fixed point
    // number with 18 decimal places). The input to this function will be just the relative annual interest rate
    // (e.g. 0.05 for 5% interest), and the result will be the per-second multiplier (e.g. 1.000000000001).
    access(all) view fun perSecondInterestRate(yearlyRate: UInt64): UInt64 {
        let perSecondScaledValue = TidalProtocolUtils.div(UInt256(yearlyRate), TidalProtocolUtils.secondsInYearE18)
        assert(perSecondScaledValue < UInt256(UInt64.max), message: "Per-second interest rate \(perSecondScaledValue) is too high")
        return UInt64(perSecondScaledValue + TidalProtocolUtils.e18)
    }

    /// Returns the compounded interest index reflecting the passage of time
    /// The result is: newIndex = oldIndex * perSecondRate ^ seconds
    // access(all) view fun compoundInterestIndex(oldIndex: UInt64, perSecondRate: UInt64, elapsedSeconds: UFix64): UInt64 {
    access(all) fun compoundInterestIndex(oldIndex: UInt256, perSecondRate: UInt64, elapsedSeconds: UFix64): UInt256 {
        var result = oldIndex
        var current = UInt256(perSecondRate)
        var secondsCounter = UInt64(elapsedSeconds)

        while secondsCounter > 0 {
            if secondsCounter & 1 == 1 {
                result = TidalProtocol.interestMul(result, current)
            }
            current = TidalProtocol.interestMul(current, current)
            secondsCounter = secondsCounter >> 1
        }

        return result
    }

    /// Transforms the provided `scaledBalance` to a true balance (or actual balance) where the true balance is the
    /// scaledBalance + accrued interest and the scaled balance is the amount a borrower has actually interacted with
    /// (via deposits or withdrawals)
    access(all) view fun scaledBalanceToTrueBalance(_ scaled: UInt256, interestIndex: UInt256): UInt256 {
        // The interest index is a fixed point number with 18 decimal places. To maintain precision,
        // we multiply the scaled balance by the interest index and then divide by 10^18 to get the
        // true balance with proper decimal alignment.
        return TidalProtocolUtils.div(
            TidalProtocolUtils.mul(scaled, interestIndex),
            TidalProtocolUtils.e18
        )
    }

    /// Transforms the provided `trueBalance` to a scaled balance where the scaled balance is the amount a borrower has
    /// actually interacted with (via deposits or withdrawals) and the true balance is the amount with respect to
    /// accrued interest
    access(all) view fun trueBalanceToScaledBalance(_ trueBalance: UInt256, interestIndex: UInt256): UInt256 {
        // The interest index is a fixed point number with 18 decimal places. To maintain precision,
        // we multiply the true balance by 10^18 and then divide by the interest index to get the
        // scaled balance with proper decimal alignment.
        return TidalProtocolUtils.div(
            TidalProtocolUtils.mul(trueBalance, TidalProtocolUtils.e18),
            interestIndex
        )
    }

    /* --- INTERNAL METHODS --- */

    /// Returns an authorized reference to the contract account's Pool resource
    access(self) view fun _borrowPool(): auth(EPosition) &Pool {
        return self.account.storage.borrow<auth(EPosition) &Pool>(from: self.PoolStoragePath)
            ?? panic("Could not borrow reference to internal TidalProtocol Pool resource")
    }

    /// Returns a reference to the contract account's MOET Minter resource
    access(self) view fun _borrowMOETMinter(): &MOET.Minter {
        return self.account.storage.borrow<&MOET.Minter>(from: MOET.AdminStoragePath)
            ?? panic("Could not borrow reference to internal MOET Minter resource")
    }

    init() {
        self.PoolStoragePath = StoragePath(identifier: "tidalProtocolPool_\(self.account.address)")!
        self.PoolFactoryPath = StoragePath(identifier: "tidalProtocolPoolFactory_\(self.account.address)")!
        self.PoolPublicPath = PublicPath(identifier: "tidalProtocolPool_\(self.account.address)")!

        // save PoolFactory in storage
        self.account.storage.save(
            <-create PoolFactory(),
            to: self.PoolFactoryPath
        )
        let factory = self.account.storage.borrow<&PoolFactory>(from: self.PoolFactoryPath)!
    }
}
