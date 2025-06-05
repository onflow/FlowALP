import "FungibleToken"
import "ViewResolver"
import "MetadataViews"
import "FungibleTokenMetadataViews"

import "DFB"
import "MOET"

access(all) contract TidalProtocol: FungibleToken {

    access(all) entitlement Withdraw

    // REMOVED: FlowVault resource implementation (previously lines 12-56)
    // The FlowVault resource has been removed to prevent type conflicts
    // with the real FlowToken.Vault when integrating with Tidal contracts.
    // All references to FlowVault will now use FlowToken.Vault instead.

    access(all) entitlement EPosition
    access(all) entitlement EGovernance
    access(all) entitlement EImplementation

    // RESTORED: BalanceSheet and health computation from Dieter's implementation
    // A convenience function for computing a health value from effective collateral and debt values.
    access(all) fun healthComputation(effectiveCollateral: UFix64, effectiveDebt: UFix64): UFix64 {
        var health = 0.0

        if effectiveCollateral == 0.0 {
            health = 0.0
        } else if effectiveDebt == 0.0 {
            health = UFix64.max
        } else if (effectiveDebt / effectiveCollateral) == 0.0 {
            // If debt is so small relative to collateral that division rounds to zero,
            // the health is essentially infinite
            health = UFix64.max
        } else {
            health = effectiveCollateral / effectiveDebt
        }

        return health
    }

    access(all) struct BalanceSheet {
        access(all) let effectiveCollateral: UFix64
        access(all) let effectiveDebt: UFix64
        access(all) let health: UFix64

        init(effectiveCollateral: UFix64, effectiveDebt: UFix64) {
            self.effectiveCollateral = effectiveCollateral
            self.effectiveDebt = effectiveDebt
            self.health = TidalProtocol.healthComputation(effectiveCollateral: effectiveCollateral, effectiveDebt: effectiveDebt)
        }
    }

    // A structure used internally to track a position's balance for a particular token.
    access(all) struct InternalBalance {
        access(all) var direction: BalanceDirection

        // Interally, position balances are tracked using a "scaled balance". The "scaled balance" is the
        // actual balance divided by the current interest index for the associated token. This means we don't
        // need to update the balance of a position as time passes, even as interest rates change. We only need
        // to update the scaled balance when the user deposits or withdraws funds. The interest index
        // is a number relatively close to 1.0, so the scaled balance will be roughly of the same order
        // of magnitude as the actual balance (thus we can use UFix64 for the scaled balance).
        access(all) var scaledBalance: UFix64

        init() {
            self.direction = BalanceDirection.Credit
            self.scaledBalance = 0.0
        }

        access(all) fun recordDeposit(amount: UFix64, tokenState: auth(EImplementation) &TokenState) {
            if self.direction == BalanceDirection.Credit {
                // Depositing into a credit position just increases the balance.

                // To maximize precision, we could convert the scaled balance to a true balance, add the
                // deposit amount, and then convert the result back to a scaled balance. However, this will
                // only cause problems for very small deposits (fractions of a cent), so we save computational
                // cycles by just scaling the deposit amount and adding it directly to the scaled balance.
                let scaledDeposit = TidalProtocol.trueBalanceToScaledBalance(trueBalance: amount,
                    interestIndex: tokenState.creditInterestIndex)

                self.scaledBalance = self.scaledBalance + scaledDeposit

                // Increase the total credit balance for the token
                tokenState.updateCreditBalance(amount: Fix64(amount))
            } else {
                // When depositing into a debit position, we first need to compute the true balance to see
                // if this deposit will flip the position from debit to credit.
                let trueBalance = TidalProtocol.scaledBalanceToTrueBalance(scaledBalance: self.scaledBalance,
                    interestIndex: tokenState.debitInterestIndex)

                if trueBalance > amount {
                    // The deposit isn't big enough to clear the debt, so we just decrement the debt.
                    let updatedBalance = trueBalance - amount

                    self.scaledBalance = TidalProtocol.trueBalanceToScaledBalance(trueBalance: updatedBalance,
                        interestIndex: tokenState.debitInterestIndex)

                    // Decrease the total debit balance for the token
                    tokenState.updateDebitBalance(amount: -1.0 * Fix64(amount))
                } else {
                    // The deposit is enough to clear the debt, so we switch to a credit position.
                    let updatedBalance = amount - trueBalance

                    self.direction = BalanceDirection.Credit
                    self.scaledBalance = TidalProtocol.trueBalanceToScaledBalance(trueBalance: updatedBalance,
                        interestIndex: tokenState.creditInterestIndex)

                    // Increase the credit balance AND decrease the debit balance
                    tokenState.updateCreditBalance(amount: Fix64(updatedBalance))
                    tokenState.updateDebitBalance(amount: -1.0 * Fix64(trueBalance))
                }
            }
        }

        access(all) fun recordWithdrawal(amount: UFix64, tokenState: &TokenState) {
            if self.direction == BalanceDirection.Debit {
                // Withdrawing from a debit position just increases the debt amount.

                // To maximize precision, we could convert the scaled balance to a true balance, subtract the
                // withdrawal amount, and then convert the result back to a scaled balance. However, this will
                // only cause problems for very small withdrawals (fractions of a cent), so we save computational
                // cycles by just scaling the withdrawal amount and subtracting it directly from the scaled balance.
                let scaledWithdrawal = TidalProtocol.trueBalanceToScaledBalance(trueBalance: amount,
                    interestIndex: tokenState.debitInterestIndex)

                self.scaledBalance = self.scaledBalance + scaledWithdrawal

                // Increase the total debit balance for the token
                tokenState.updateDebitBalance(amount: Fix64(amount))
            } else {
                // When withdrawing from a credit position, we first need to compute the true balance to see
                // if this withdrawal will flip the position from credit to debit.
                let trueBalance = TidalProtocol.scaledBalanceToTrueBalance(scaledBalance: self.scaledBalance,
                    interestIndex: tokenState.creditInterestIndex)

                if trueBalance >= amount {
                    // The withdrawal isn't big enough to push the position into debt, so we just decrement the
                    // credit balance.
                    let updatedBalance = trueBalance - amount

                    self.scaledBalance = TidalProtocol.trueBalanceToScaledBalance(trueBalance: updatedBalance,
                        interestIndex: tokenState.creditInterestIndex)

                    // Decrease the total credit balance for the token
                    tokenState.updateCreditBalance(amount: -1.0 * Fix64(amount))
                } else {
                    // The withdrawal is enough to push the position into debt, so we switch to a debit position.
                    let updatedBalance = amount - trueBalance

                    self.direction = BalanceDirection.Debit
                    self.scaledBalance = TidalProtocol.trueBalanceToScaledBalance(trueBalance: updatedBalance,
                        interestIndex: tokenState.debitInterestIndex)

                    // Decrease the credit balance AND increase the debit balance
                    tokenState.updateCreditBalance(amount: -1.0 * Fix64(trueBalance))
                    tokenState.updateDebitBalance(amount: Fix64(updatedBalance))
                }
            }
        }
    }

    access(all) entitlement mapping ImplementationUpdates {
        EImplementation -> Mutate
        EImplementation -> FungibleToken.Withdraw
    }

    // RESTORED: InternalPosition as resource per Dieter's design
    // This MUST be a resource to properly manage queued deposits
    access(all) resource InternalPosition {
        access(mapping ImplementationUpdates) var balances: {Type: InternalBalance}
        access(mapping ImplementationUpdates) var queuedDeposits: @{Type: {FungibleToken.Vault}}
        access(EImplementation) var targetHealth: UFix64
        access(EImplementation) var minHealth: UFix64
        access(EImplementation) var maxHealth: UFix64
        access(EImplementation) var drawDownSink: {DFB.Sink}?
        access(EImplementation) var topUpSource: {DFB.Source}?

        init() {
            self.balances = {}
            self.queuedDeposits <- {}
            self.targetHealth = 1.3
            self.minHealth = 1.1
            self.maxHealth = 1.5
            self.drawDownSink = nil
            self.topUpSource = nil
        }

        access(EImplementation) fun setDrawDownSink(_ sink: {DFB.Sink}?) {
            self.drawDownSink = sink
        }

        access(EImplementation) fun setTopUpSource(_ source: {DFB.Source}?) {
            self.topUpSource = source
        }
    }

    access(all) struct interface InterestCurve {
        access(all) fun interestRate(creditBalance: UFix64, debitBalance: UFix64): UFix64
        {
            post {
                result <= 1.0: "Interest rate can't exceed 100%"
            }
        }
    }

    access(all) struct SimpleInterestCurve: InterestCurve {
        access(all) fun interestRate(creditBalance: UFix64, debitBalance: UFix64): UFix64 {
            return 0.0
        }
    }

    // A multiplication function for interest calcuations. It assumes that both values are very close to 1
    // and represent fixed point numbers with 16 decimal places of precision.
    access(all) fun interestMul(_ a: UInt64, _ b: UInt64): UInt64 {
        let aScaled = a / 100000000
        let bScaled = b / 100000000

        return aScaled * bScaled
    }

    // Converts a yearly interest rate (as a UFix64) to a per-second multiplication factor
    // (stored in a UInt64 as a fixed point number with 16 decimal places). The input to this function will be
    // just the relative interest rate (e.g. 0.05 for 5% interest), but the result will be
    // the per-second multiplier (e.g. 1.000000000001).
    access(all) fun perSecondInterestRate(yearlyRate: UFix64): UInt64 {
        // Covert the yearly rate to an integer maintaning the 10^8 multiplier of UFix64.
        // We would need to multiply by an additional 10^8 to match the promised multiplier of
        // 10^16. HOWEVER, since we are about to divide by 31536000, we can save multiply a factor
        // 1000 smaller, and then divide by 31536.
        let yearlyScaledValue = UInt64.fromBigEndianBytes(yearlyRate.toBigEndianBytes())! * 100000
        let perSecondScaledValue = (yearlyScaledValue / 31536) + 10000000000000000

        return perSecondScaledValue
    }

    // Updates an interest index to reflect the passage of time. The result is:
    //   newIndex = oldIndex * perSecondRate^seconds
    access(all) fun compoundInterestIndex(oldIndex: UInt64, perSecondRate: UInt64, elapsedSeconds: UFix64): UInt64 {
        var result = oldIndex
        var current = perSecondRate
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

    access(all) fun scaledBalanceToTrueBalance(scaledBalance: UFix64, interestIndex: UInt64): UFix64 {
        // The interest index is essentially a fixed point number with 16 decimal places, we convert
        // it to a UFix64 by copying the byte representation, and then dividing by 10^8 (leaving and
        // additional 10^8 as required for the UFix64 representation).
        let indexMultiplier = UFix64.fromBigEndianBytes(interestIndex.toBigEndianBytes())! / 100000000.0
        return scaledBalance * indexMultiplier
    }

    access(all) fun trueBalanceToScaledBalance(trueBalance: UFix64, interestIndex: UInt64): UFix64 {
        // The interest index is essentially a fixed point number with 16 decimal places, we convert
        // it to a UFix64 by copying the byte representation, and then dividing by 10^8 (leaving and
        // additional 10^8 as required for the UFix64 representation).
        let indexMultiplier = UFix64.fromBigEndianBytes(interestIndex.toBigEndianBytes())! / 100000000.0
        return trueBalance / indexMultiplier
    }

    access(all) struct TokenState {
        access(all) var lastUpdate: UFix64
        access(all) var totalCreditBalance: UFix64
        access(all) var totalDebitBalance: UFix64
        access(all) var creditInterestIndex: UInt64
        access(all) var debitInterestIndex: UInt64
        access(all) var currentCreditRate: UInt64
        access(all) var currentDebitRate: UInt64
        access(all) var interestCurve: {InterestCurve}

        // RESTORED: Deposit rate limiting from Dieter's implementation
        access(all) var depositRate: UFix64
        access(all) var depositCapacity: UFix64
        access(all) var depositCapacityCap: UFix64

        access(all) fun updateCreditBalance(amount: Fix64) {
            // temporary cast the credit balance to a signed value so we can add/subtract
            let adjustedBalance = Fix64(self.totalCreditBalance) + amount
            self.totalCreditBalance = UFix64(adjustedBalance)
        }

        access(all) fun updateDebitBalance(amount: Fix64) {
            // temporary cast the debit balance to a signed value so we can add/subtract
            let adjustedBalance = Fix64(self.totalDebitBalance) + amount
            self.totalDebitBalance = UFix64(adjustedBalance)
        }

        // RESTORED: Enhanced updateInterestIndices with deposit capacity update
        access(all) fun updateInterestIndices() {
            let currentTime = getCurrentBlock().timestamp
            let timeDelta = currentTime - self.lastUpdate
            self.creditInterestIndex = TidalProtocol.compoundInterestIndex(oldIndex: self.creditInterestIndex, perSecondRate: self.currentCreditRate, elapsedSeconds: timeDelta)
            self.debitInterestIndex = TidalProtocol.compoundInterestIndex(oldIndex: self.debitInterestIndex, perSecondRate: self.currentDebitRate, elapsedSeconds: timeDelta)
            self.lastUpdate = currentTime

            // RESTORED: Update deposit capacity based on time
            let newDepositCapacity = self.depositCapacity + (self.depositRate * timeDelta)
            if newDepositCapacity >= self.depositCapacityCap {
                self.depositCapacity = self.depositCapacityCap
            } else {
                self.depositCapacity = newDepositCapacity
            }
        }

        // RESTORED: Deposit limit function from Dieter's implementation
        access(all) fun depositLimit(): UFix64 {
            // Each deposit is limited to 5% of the total deposit capacity
            return self.depositCapacity * 0.05
        }

        // RESTORED: Rename to updateForTimeChange to match Dieter's implementation
        access(all) fun updateForTimeChange() {
            self.updateInterestIndices()
        }

        access(all) fun updateInterestRates() {
            // If there's no credit balance, we can't calculate a meaningful credit rate
            // so we'll just set both rates to zero and return early
            if self.totalCreditBalance <= 0.0 {
                self.currentCreditRate = 10000000000000000  // 1.0 in fixed point (no interest)
                self.currentDebitRate = 10000000000000000   // 1.0 in fixed point (no interest)
                return
            }

            let debitRate = self.interestCurve.interestRate(creditBalance: self.totalCreditBalance, debitBalance: self.totalDebitBalance)
            let debitIncome = self.totalDebitBalance * (1.0 + debitRate)
            
                         // Calculate insurance amount (0.1% of credit balance)
             let insuranceAmount = self.totalCreditBalance * 0.001
            
            // Calculate credit rate, ensuring we don't have underflows
            var creditRate: UFix64 = 0.0
            if debitIncome >= insuranceAmount {
                creditRate = ((debitIncome - insuranceAmount) / self.totalCreditBalance) - 1.0
            } else {
                // If debit income doesn't cover insurance, we have a negative credit rate
                // but since we can't represent negative rates in our model, we'll use 0.0
                creditRate = 0.0
            }
            
            self.currentCreditRate = TidalProtocol.perSecondInterestRate(yearlyRate: creditRate)
            self.currentDebitRate = TidalProtocol.perSecondInterestRate(yearlyRate: debitRate)
        }

        // RESTORED: Parameterized init from Dieter's implementation
        init(interestCurve: {InterestCurve}, depositRate: UFix64, depositCapacityCap: UFix64) {
            self.lastUpdate = 0.0
            self.totalCreditBalance = 0.0
            self.totalDebitBalance = 0.0
            self.creditInterestIndex = 10000000000000000
            self.debitInterestIndex = 10000000000000000
            self.currentCreditRate = 10000000000000000
            self.currentDebitRate = 10000000000000000
            self.interestCurve = interestCurve
            self.depositRate = depositRate
            self.depositCapacity = depositCapacityCap
            self.depositCapacityCap = depositCapacityCap
        }
    }

    access(all) resource Pool {
        // A simple version number that is incremented whenever one or more interest indices
        // are updated. This is used to detect when the interest indices need to be updated in
        // InternalPositions.
        access(EImplementation) var version: UInt64

        // Global state for tracking each token
        access(self) var globalLedger: {Type: TokenState}

        // Individual user positions - RESTORED as resources per Dieter's design
        access(self) var positions: @{UInt64: InternalPosition}

        // The actual reserves of each token
        access(self) var reserves: @{Type: {FungibleToken.Vault}}

        // Auto-incrementing position identifier counter
        access(self) var nextPositionID: UInt64

        // The default token type used as the "unit of account" for the pool.
        access(self) let defaultToken: Type

        // RESTORED: Price oracle from Dieter's implementation
        // A price oracle that will return the price of each token in terms of the default token.
        access(self) var priceOracle: {DFB.PriceOracle}

        // RESTORED: Position update queue from Dieter's implementation
        access(EImplementation) var positionsNeedingUpdates: [UInt64]
        access(self) var positionsProcessedPerCallback: UInt64

        // RESTORED: Collateral and borrow factors from Dieter's implementation
        // These dictionaries determine borrowing limits. Each token has a collateral factor and a
        // borrow factor.
        //
        // When determining the total collateral amount that can be borrowed against, the value of the
        // token (as given by the oracle) is multiplied by the collateral factor. So, a token with a
        // collateral factor of 0.8 would only allow you to borrow 80% as much as if you had a the same
        // value of a token with a collateral factor of 1.0. The total "effective collateral" for a
        // position is the value of each token multiplied by its collateral factor.
        //
        // At the same time, the "borrow factor" determines if the user can borrow against all of that
        // effective collateral, or if they can only borrow a portion of it to manage risk.
        access(self) var collateralFactor: {Type: UFix64}
        access(self) var borrowFactor: {Type: UFix64}

        // REMOVED: Static exchange rates and liquidation thresholds
        // These have been replaced by dynamic oracle pricing and risk factors

        // RESTORED: tokenState() helper function from Dieter's implementation
        // A convenience function that returns a reference to a particular token state, making sure
        // it's up-to-date for the passage of time. This should always be used when accessing a token
        // state to avoid missing interest updates (duplicate calls to updateForTimeChange() are a nop
        // within a single block).
        access(self) fun tokenState(type: Type): auth(EImplementation) &TokenState {
            let state = &self.globalLedger[type]! as auth(EImplementation) &TokenState
            state.updateForTimeChange()
            return state
        }

        init(defaultToken: Type, priceOracle: {DFB.PriceOracle}) {
            pre {
                priceOracle.unitOfAccount() == defaultToken: "Price oracle must return prices in terms of the default token"
            }

            self.version = 0
            self.globalLedger = {defaultToken: TokenState(
                interestCurve: SimpleInterestCurve(),
                depositRate: 1000000.0,        // Default: no rate limiting for default token
                depositCapacityCap: 1000000.0  // Default: high capacity cap
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

        // Add a new token type to the pool
        // This function should only be called by governance in the future
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
                collateralFactor > 0.0 && collateralFactor <= 1.0: "Collateral factor must be between 0 and 1"
                borrowFactor > 0.0 && borrowFactor <= 1.0: "Borrow factor must be between 0 and 1"
                depositRate > 0.0: "Deposit rate must be positive"
                depositCapacityCap > 0.0: "Deposit capacity cap must be positive"
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

        // Get supported token types
        access(all) fun getSupportedTokens(): [Type] {
            return self.globalLedger.keys
        }

        // Check if a token type is supported
        access(all) fun isTokenSupported(tokenType: Type): Bool {
            return self.globalLedger[tokenType] != nil
        }

        access(EPosition) fun deposit(pid: UInt64, funds: @{FungibleToken.Vault}) {
            pre {
                self.positions[pid] != nil: "Invalid position ID"
                self.globalLedger[funds.getType()] != nil: "Invalid token type"
                funds.balance > 0.0: "Deposit amount must be positive"
            }

            // Get a reference to the user's position and global token state for the affected token.
            let type = funds.getType()
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!
            let tokenState = self.tokenState(type: type)

            // If this position doesn't currently have an entry for this token, create one.
            if position.balances[type] == nil {
                position.balances[type] = InternalBalance()
            }

            // Update the global interest indices on the affected token to reflect the passage of time.
            // REMOVED: This is now handled by tokenState() helper function
            // tokenState.updateInterestIndices()

            // CHANGE: Create vault if it doesn't exist yet
            if self.reserves[type] == nil {
                self.reserves[type] <-! funds.createEmptyVault()
            }
            let reserveVault = (&self.reserves[type] as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?)!

            // Reflect the deposit in the position's balance
            position.balances[type]!.recordDeposit(amount: funds.balance, tokenState: tokenState)

            // Update the internal interest rate to reflect the new credit balance
            tokenState.updateInterestRates()

            // Add the money to the reserves
            reserveVault.deposit(from: <-funds)
        }

        // RESTORED: Public deposit function from Dieter's implementation
        // Allows anyone to deposit funds into any position
        access(all) fun depositToPosition(pid: UInt64, from: @{FungibleToken.Vault}) {
            self.depositAndPush(pid: pid, from: <-from, pushToDrawDownSink: false)
        }

        // RESTORED: Enhanced deposit with queue processing and rebalancing from Dieter's implementation
        access(EPosition) fun depositAndPush(pid: UInt64, from: @{FungibleToken.Vault}, pushToDrawDownSink: Bool) {
            pre {
                self.positions[pid] != nil: "Invalid position ID"
                self.globalLedger[from.getType()] != nil: "Invalid token type"
            }

            if from.balance == 0.0 {
                destroy from
                return
            }

            // Get a reference to the user's position and global token state for the affected token.
            let type = from.getType()
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!
            let tokenState = self.tokenState(type: type)

            // Update time-based state
            // REMOVED: This is now handled by tokenState() helper function
            // tokenState.updateForTimeChange()

            // RESTORED: Deposit rate limiting from Dieter's implementation
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
            position.balances[type]!.recordDeposit(amount: from.balance, tokenState: tokenState)

            // Add the money to the reserves
            reserveVault.deposit(from: <-from)

            // RESTORED: Rebalancing and queue management
            if pushToDrawDownSink {
                self.rebalancePosition(pid: pid, force: true)
            }

            self.queuePositionForUpdateIfNecessary(pid: pid)
        }

        access(EPosition) fun withdraw(pid: UInt64, amount: UFix64, type: Type): @{FungibleToken.Vault} {
            // RESTORED: Call the enhanced function with pullFromTopUpSource = false for backward compatibility
            return <- self.withdrawAndPull(pid: pid, type: type, amount: amount, pullFromTopUpSource: false)
        }

        // RESTORED: Enhanced withdraw with top-up source integration from Dieter's implementation
        access(EPosition) fun withdrawAndPull(
            pid: UInt64, 
            type: Type, 
            amount: UFix64, 
            pullFromTopUpSource: Bool
        ): @{FungibleToken.Vault} {
            pre {
                self.positions[pid] != nil: "Invalid position ID"
                self.globalLedger[type] != nil: "Invalid token type"
                amount > 0.0: "Withdrawal amount must be positive"
            }

            // Get a reference to the user's position and global token state for the affected token.
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!
            let tokenState = self.tokenState(type: type)

            // Update the global interest indices on the affected token to reflect the passage of time.
            // REMOVED: This is now handled by tokenState() helper function
            // tokenState.updateForTimeChange()

            // RESTORED: Top-up source integration from Dieter's implementation
            // Preflight to see if the funds are available
            let topUpSource = position.topUpSource as! auth(FungibleToken.Withdraw) &{DFB.Source}?
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

                    let pulledVault <- (topUpSource!).withdrawAvailable(maxAmount: idealDeposit)

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
                // We can't service this withdrawal, so we just abort
                panic("Insufficient funds for withdrawal")
            }

            // If this position doesn't currently have an entry for this token, create one.
            if position.balances[type] == nil {
                position.balances[type] = InternalBalance()
            }

            let reserveVault = (&self.reserves[type] as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?)!

            // Reflect the withdrawal in the position's balance
            position.balances[type]!.recordWithdrawal(amount: amount, tokenState: tokenState)

            // Ensure that this withdrawal doesn't cause the position to be overdrawn.
            assert(self.positionHealth(pid: pid) >= 1.0, message: "Position is overdrawn")

            // Queue for update if necessary
            self.queuePositionForUpdateIfNecessary(pid: pid)

            return <- reserveVault.withdraw(amount: amount)
        }

        // RESTORED: Position queue management from Dieter's implementation
        access(self) fun queuePositionForUpdateIfNecessary(pid: UInt64) {
            if self.positionsNeedingUpdates.contains(pid) {
                // If this position is already queued for an update, no need to check anything else
                return
            } else {
                // If this position is not already queued for an update, we need to check if it needs one
                let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!

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
        }

        // RESTORED: Position rebalancing from Dieter's implementation
        // Rebalances the position to the target health value. If force is true, the position will be
        // rebalanced even if it is currently healthy, otherwise, this function will do nothing if the
        // position is within the min/max health bounds.
        access(EPosition) fun rebalancePosition(pid: UInt64, force: Bool) {
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!
            let balanceSheet = self.positionBalanceSheet(pid: pid)

            if !force && (balanceSheet.health >= position.minHealth && balanceSheet.health <= position.maxHealth) {
                // We aren't forcing the update, and the position is already between its desired min and max. Nothing to do!
                return
            }

            if balanceSheet.health < position.targetHealth {
                // The position is undercollateralized, see if the source can get more collateral to bring it up to the target health.
                if position.topUpSource != nil {
                    let topUpSource = position.topUpSource!
                    let idealDeposit = self.fundsRequiredForTargetHealth(
                        pid: pid, 
                        type: topUpSource.getSourceType(), 
                        targetHealth: position.targetHealth
                    )

                    let pulledVault <- topUpSource.withdrawAvailable(maxAmount: idealDeposit)
                    self.depositAndPush(pid: pid, from: <-pulledVault, pushToDrawDownSink: false)
                }
            } else if balanceSheet.health > position.targetHealth {
                // The position is overcollateralized, we'll withdraw funds to match the target health and offer it to the sink.
                if position.drawDownSink != nil {
                    let drawDownSink = position.drawDownSink!
                    let sinkType = drawDownSink.getSinkType()
                    let idealWithdrawal = self.fundsAvailableAboveTargetHealth(
                        pid: pid, 
                        type: sinkType, 
                        targetHealth: position.targetHealth
                    )

                    // Compute how many tokens of the sink's type are available to hit our target health.
                    let sinkCapacity = drawDownSink.minimumCapacity()
                    let sinkAmount = (idealWithdrawal > sinkCapacity) ? sinkCapacity : idealWithdrawal
                    
                    if sinkAmount > 0.0 {
                        let sinkVault <- self.withdrawAndPull(
                            pid: pid, 
                            type: sinkType, 
                            amount: sinkAmount, 
                            pullFromTopUpSource: false
                        )

                        // Push what we can into the sink, and redeposit the rest
                        drawDownSink.depositCapacity(from: &sinkVault as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
                        
                        if sinkVault.balance > 0.0 {
                            self.depositAndPush(pid: pid, from: <-sinkVault, pushToDrawDownSink: false)
                        } else {
                            destroy sinkVault
                        }
                    }
                }
            }
        }

        // RESTORED: Provider functions for sink/source from Dieter's implementation
        access(EPosition) fun provideDrawDownSink(pid: UInt64, sink: {DFB.Sink}?) {
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!
            position.setDrawDownSink(sink)
        }
            
        access(EPosition) fun provideTopUpSource(pid: UInt64, source: {DFB.Source}?) {
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!
            position.setTopUpSource(source)
        }

        // RESTORED: Available balance with source integration from Dieter's implementation
        access(all) fun availableBalance(pid: UInt64, type: Type, pullFromTopUpSource: Bool): UFix64 {
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!

            if pullFromTopUpSource && position.topUpSource != nil {
                let topUpSource = position.topUpSource!
                let sourceType = topUpSource.getSourceType()
                let sourceAmount = topUpSource.minimumAvailable()

                return self.fundsAvailableAboveTargetHealthAfterDepositing(
                    pid: pid, 
                    withdrawType: type, 
                    targetHealth: position.minHealth,
                    depositType: sourceType, 
                    depositAmount: sourceAmount
                )
            } else {
                return self.fundsAvailableAboveTargetHealth(
                    pid: pid, 
                    type: type, 
                    targetHealth: position.minHealth
                )
            }
        }

        // Returns the health of the given position, which is the ratio of the position's effective collateral
        // to its debt (as denominated in the default token). ("Effective collateral" means the
        // value of each credit balance times the liquidation threshold for that token. i.e. the maximum borrowable amount)
        access(all) fun positionHealth(pid: UInt64): UFix64 {
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!

            // Get the position's collateral and debt values in terms of the default token.
            var effectiveCollateral = 0.0
            var effectiveDebt = 0.0

            for type in position.balances.keys {
                let balance = position.balances[type]!
                let tokenState = self.tokenState(type: type)
                if balance.direction == BalanceDirection.Credit {
                    let trueBalance = TidalProtocol.scaledBalanceToTrueBalance(scaledBalance: balance.scaledBalance,
                        interestIndex: tokenState.creditInterestIndex)

                    // RESTORED: Oracle-based pricing from Dieter's implementation
                    let tokenPrice = self.priceOracle.price(token: type)
                    let value = tokenPrice * trueBalance
                    effectiveCollateral = effectiveCollateral + (value * self.collateralFactor[type]!)
                } else {
                    let trueBalance = TidalProtocol.scaledBalanceToTrueBalance(scaledBalance: balance.scaledBalance,
                        interestIndex: tokenState.debitInterestIndex)

                    // RESTORED: Oracle-based pricing for debt calculation
                    let tokenPrice = self.priceOracle.price(token: type)
                    let value = tokenPrice * trueBalance
                    effectiveDebt = effectiveDebt + (value / self.borrowFactor[type]!)
                }
            }

            // Calculate the health as the ratio of collateral to debt.
            if effectiveDebt == 0.0 {
                return 1.0
            }
            return effectiveCollateral / effectiveDebt
        }

        // RESTORED: Position balance sheet calculation from Dieter's implementation
        access(self) fun positionBalanceSheet(pid: UInt64): BalanceSheet {
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!
            let priceOracle = &self.priceOracle as &{DFB.PriceOracle}

            // Get the position's collateral and debt values in terms of the default token.
            var effectiveCollateral = 0.0
            var effectiveDebt = 0.0

            for type in position.balances.keys {
                let balance = position.balances[type]!
                let tokenState = self.tokenState(type: type)
                if balance.direction == BalanceDirection.Credit {
                    let trueBalance = TidalProtocol.scaledBalanceToTrueBalance(scaledBalance: balance.scaledBalance,
                        interestIndex: tokenState.creditInterestIndex)
                    
                    let value = priceOracle.price(token: type) * trueBalance

                    effectiveCollateral = effectiveCollateral + (value * self.collateralFactor[type]!)
                } else {
                    let trueBalance = TidalProtocol.scaledBalanceToTrueBalance(scaledBalance: balance.scaledBalance,
                        interestIndex: tokenState.debitInterestIndex)

                    let value = priceOracle.price(token: type) * trueBalance

                    effectiveDebt = effectiveDebt + (value / self.borrowFactor[type]!)
                }
            }

            return BalanceSheet(effectiveCollateral: effectiveCollateral, effectiveDebt: effectiveDebt)
        }

        access(all) fun createPosition(): UInt64 {
            let id = self.nextPositionID
            self.nextPositionID = self.nextPositionID + 1
            self.positions[id] <-! create InternalPosition()
            return id
        }

        // Helper function for testing – returns the current reserve balance for the specified token type.
        access(all) fun reserveBalance(type: Type): UFix64 {
            // CHANGE: Handle case where no vault exists yet for this token type
            let vaultRef = (&self.reserves[type] as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?)
            if vaultRef == nil {
                return 0.0
            }
            return vaultRef!.balance
        }

        // Add getPositionDetails function that's used by DFB implementations
        access(all) fun getPositionDetails(pid: UInt64): PositionDetails {
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!
            let balances: [PositionBalance] = []
            
            for type in position.balances.keys {
                let balance = position.balances[type]!
                let tokenState = self.tokenState(type: type)
                
                let trueBalance = balance.direction == BalanceDirection.Credit
                    ? TidalProtocol.scaledBalanceToTrueBalance(scaledBalance: balance.scaledBalance, interestIndex: tokenState.creditInterestIndex)
                    : TidalProtocol.scaledBalanceToTrueBalance(scaledBalance: balance.scaledBalance, interestIndex: tokenState.debitInterestIndex)
                
                balances.append(PositionBalance(
                    type: type,
                    direction: balance.direction,
                    balance: trueBalance
                ))
            }
            
            let health = self.positionHealth(pid: pid)
            
            return PositionDetails(
                balances: balances,
                poolDefaultToken: self.defaultToken,
                defaultTokenAvailableBalance: 0.0, // TODO: Calculate this properly
                health: health
            )
        }

        // RESTORED: Advanced position health management functions from Dieter's implementation
        
        // The quantity of funds of a specified token which would need to be deposited to bring the
        // position to the target health. This function will return 0.0 if the position is already at or over
        // that health value.
        access(all) fun fundsRequiredForTargetHealth(pid: UInt64, type: Type, targetHealth: UFix64): UFix64 {
            return self.fundsRequiredForTargetHealthAfterWithdrawing(
                pid: pid, 
                depositType: type, 
                targetHealth: targetHealth, 
                withdrawType: self.defaultToken, 
                withdrawAmount: 0.0
            )
        }

        // The quantity of funds of a specified token which would need to be deposited to bring the
        // position to the target health assuming we also withdraw a specified amount of another
        // token. This function will return 0.0 if the position would already be at or over the target
        // health value after the proposed withdrawal.
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

            let balanceSheet = self.positionBalanceSheet(pid: pid)
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!

            var effectiveCollateralAfterWithdrawal = balanceSheet.effectiveCollateral
            var effectiveDebtAfterWithdrawal = balanceSheet.effectiveDebt

            if withdrawAmount != 0.0 {
                if position.balances[withdrawType] == nil || position.balances[withdrawType]!.direction == BalanceDirection.Debit {
                    // If the position doesn't have any collateral for the withdrawn token, we can just compute how much
                    // additional effective debt the withdrawal will create.
                    effectiveDebtAfterWithdrawal = balanceSheet.effectiveDebt + 
                        (withdrawAmount * self.priceOracle.price(token: withdrawType) / self.borrowFactor[withdrawType]!)
                } else {
                    let withdrawTokenState = self.tokenState(type: withdrawType)
                    // REMOVED: This is now handled by tokenState() helper function
                    // withdrawTokenState.updateForTimeChange()

                    // The user has a collateral position in the given token, we need to figure out if this withdrawal
                    // will flip over into debt, or just draw down the collateral.
                    let collateralBalance = position.balances[withdrawType]!.scaledBalance
                    let trueCollateral = TidalProtocol.scaledBalanceToTrueBalance(
                        scaledBalance: collateralBalance,
                        interestIndex: withdrawTokenState.creditInterestIndex
                    )

                    if trueCollateral >= withdrawAmount {
                        // This withdrawal will draw down collateral, but won't create debt, we just need to account
                        // for the collateral decrease.
                        effectiveCollateralAfterWithdrawal = balanceSheet.effectiveCollateral - 
                            (withdrawAmount * self.priceOracle.price(token: withdrawType) * self.collateralFactor[withdrawType]!)
                    } else {
                        // The withdrawal will wipe out all of the collateral, and create some debt.
                        effectiveDebtAfterWithdrawal = balanceSheet.effectiveDebt +
                            ((withdrawAmount - trueCollateral) * self.priceOracle.price(token: withdrawType) / self.borrowFactor[withdrawType]!)

                        effectiveCollateralAfterWithdrawal = balanceSheet.effectiveCollateral -
                            (trueCollateral * self.priceOracle.price(token: withdrawType) * self.collateralFactor[withdrawType]!)
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

            if healthAfterWithdrawal >= targetHealth {
                // The position is already at or above the target health, so we don't need to deposit anything.
                return 0.0
            }

            // For situations where the required deposit will BOTH pay off debt and accumulate collateral, we keep
            // track of the number of tokens that went towards paying off debt.
            var debtTokenCount = 0.0

            if position.balances[depositType] != nil && position.balances[depositType]!.direction == BalanceDirection.Debit {
                // The user has a debt position in the given token, we start by looking at the health impact of paying off
                // the entire debt.
                let depositTokenState = self.tokenState(type: depositType)
                // REMOVED: This is now handled by tokenState() helper function
                // depositTokenState.updateForTimeChange()
                
                let debtBalance = position.balances[depositType]!.scaledBalance
                let trueDebt = TidalProtocol.scaledBalanceToTrueBalance(
                    scaledBalance: debtBalance,
                    interestIndex: depositTokenState.debitInterestIndex
                )
                let debtEffectiveValue = self.priceOracle.price(token: depositType) * trueDebt / self.borrowFactor[depositType]!

                // Check what the new health would be if we paid off all of this debt
                let potentialHealth = TidalProtocol.healthComputation(
                    effectiveCollateral: effectiveCollateralAfterWithdrawal,
                    effectiveDebt: effectiveDebtAfterWithdrawal - debtEffectiveValue
                )

                // Does paying off all of the debt reach the target health? Then we're done.
                if potentialHealth >= targetHealth {
                    // We can reach the target health by paying off some or all of the debt. We can easily
                    // compute how many units of the token would be needed to reach the target health.
                    let healthChange = targetHealth - healthAfterWithdrawal
                    let requiredEffectiveDebt = healthChange * effectiveCollateralAfterWithdrawal / (targetHealth * targetHealth)

                    // The amount of the token to pay back, in units of the token.
                    let paybackAmount = requiredEffectiveDebt * self.borrowFactor[depositType]! / self.priceOracle.price(token: depositType)

                    return paybackAmount
                } else {
                    // We can pay off the entire debt, but we still need to deposit more to reach the target health.
                    // We have logic below that can determine the collateral deposition required to reach the target health
                    // from this new health position. Rather than copy that logic here, we fall through into it. But first
                    // we have to record the amount of tokens that went towards debt payback and adjust the effective
                    // debt to reflect that it has been paid off.
                    debtTokenCount = trueDebt
                    effectiveDebtAfterWithdrawal = effectiveDebtAfterWithdrawal - debtEffectiveValue
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
            let healthChange = targetHealth - healthAfterWithdrawal
            let requiredEffectiveCollateral = healthChange * effectiveDebtAfterWithdrawal

            // The amount of the token to deposit, in units of the token.
            let collateralTokenCount = requiredEffectiveCollateral / self.priceOracle.price(token: depositType) / self.collateralFactor[depositType]!

            // debtTokenCount is the number of tokens that went towards debt, zero if there was no debt.
            return collateralTokenCount + debtTokenCount
        }

        // Returns the quantity of the specified token that could be withdrawn while still keeping the position's health
        // at or above the provided target.
        access(all) fun fundsAvailableAboveTargetHealth(pid: UInt64, type: Type, targetHealth: UFix64): UFix64 {
            return self.fundsAvailableAboveTargetHealthAfterDepositing(
                pid: pid, 
                withdrawType: type, 
                targetHealth: targetHealth,
                depositType: self.defaultToken, 
                depositAmount: 0.0
            )
        }

        // Returns the quantity of the specified token that could be withdrawn while still keeping the position's health
        // at or above the provided target, assuming we also deposit a specified amount of another token.
        access(all) fun fundsAvailableAboveTargetHealthAfterDepositing(
            pid: UInt64, 
            withdrawType: Type, 
            targetHealth: UFix64,
            depositType: Type, 
            depositAmount: UFix64
        ): UFix64 {
            if depositType == withdrawType && depositAmount > 0.0 {
                // If the deposit and withdrawal types are the same, we compute the available funds assuming 
                // no deposit (which is less work) and increase that by the deposit amount at the end
                return self.fundsAvailableAboveTargetHealth(pid: pid, type: withdrawType, targetHealth: targetHealth) + depositAmount
            }

            let balanceSheet = self.positionBalanceSheet(pid: pid)
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!

            var effectiveCollateralAfterDeposit = balanceSheet.effectiveCollateral
            var effectiveDebtAfterDeposit = balanceSheet.effectiveDebt

            if depositAmount != 0.0 {
                if position.balances[depositType] == nil || position.balances[depositType]!.direction == BalanceDirection.Credit {
                    // If there's no debt for the deposit token, we can just compute how much additional effective collateral the deposit will create.
                    effectiveCollateralAfterDeposit = balanceSheet.effectiveCollateral + 
                        (depositAmount * self.priceOracle.price(token: depositType) * self.collateralFactor[depositType]!)
                } else {
                    let depositTokenState = self.tokenState(type: depositType)

                    // The user has a debt position in the given token, we need to figure out if this deposit
                    // will result in net collateral, or just bring down the debt.
                    let debtBalance = position.balances[depositType]!.scaledBalance
                    let trueDebt = TidalProtocol.scaledBalanceToTrueBalance(
                        scaledBalance: debtBalance,
                        interestIndex: depositTokenState.debitInterestIndex
                    )

                    if trueDebt >= depositAmount {
                        // This deposit will pay down some debt, but won't result in net collateral, we
                        // just need to account for the debt decrease.
                        effectiveDebtAfterDeposit = balanceSheet.effectiveDebt - 
                            (depositAmount * self.priceOracle.price(token: depositType) / self.borrowFactor[depositType]!)
                    } else {
                        // The deposit will wipe out all of the debt, and create some collateral.
                        effectiveDebtAfterDeposit = balanceSheet.effectiveDebt -
                            (trueDebt * self.priceOracle.price(token: depositType) / self.borrowFactor[depositType]!)

                        effectiveCollateralAfterDeposit = balanceSheet.effectiveCollateral +
                            ((depositAmount - trueDebt) * self.priceOracle.price(token: depositType) * self.collateralFactor[depositType]!)
                    }
                }
            }

            // We now have new effective collateral and debt values that reflect the proposed deposit (if any!)
            // Now we can figure out how many of the withdrawal token are available while keeping the position
            // at or above the target health value.
            var healthAfterDeposit = TidalProtocol.healthComputation(
                effectiveCollateral: effectiveCollateralAfterDeposit, 
                effectiveDebt: effectiveDebtAfterDeposit
            )

            if healthAfterDeposit <= targetHealth {
                // The position is already at or below the target health, so we can't withdraw anything.
                return 0.0
            }

            // For situations where the available withdrawal will BOTH draw down collateral and create debt, we keep
            // track of the number of tokens that are available from collateral
            var collateralTokenCount = 0.0

            if position.balances[withdrawType] != nil && position.balances[withdrawType]!.direction == BalanceDirection.Credit {
                // The user has a credit position in the withdraw token, we start by looking at the health impact of pulling out all
                // of that collateral
                let withdrawTokenState = self.tokenState(type: withdrawType)
                // REMOVED: This is now handled by tokenState() helper function
                // withdrawTokenState.updateForTimeChange()
                
                let creditBalance = position.balances[withdrawType]!.scaledBalance
                let trueCredit = TidalProtocol.scaledBalanceToTrueBalance(
                    scaledBalance: creditBalance,
                    interestIndex: withdrawTokenState.creditInterestIndex
                )
                let collateralEffectiveValue = self.priceOracle.price(token: withdrawType) * trueCredit * self.collateralFactor[withdrawType]!

                // Check what the new health would be if we took out all of this collateral
                let potentialHealth = TidalProtocol.healthComputation(
                    effectiveCollateral: effectiveCollateralAfterDeposit - collateralEffectiveValue,
                    effectiveDebt: effectiveDebtAfterDeposit
                )

                // Does drawing down all of the collateral go below the target health? Then the max withdrawal comes from collateral only.
                if potentialHealth <= targetHealth {
                    // We will hit the health target before using up all of the withdraw token credit. We can easily
                    // compute how many units of the token would bring the position down to the target health.
                    let availableHealth = healthAfterDeposit - targetHealth
                    let availableEffectiveValue = availableHealth * effectiveDebtAfterDeposit

                    // The amount of the token we can take using that amount of health
                    let availableTokenCount = availableEffectiveValue / self.collateralFactor[withdrawType]! / self.priceOracle.price(token: withdrawType)

                    return availableTokenCount
                } else {
                    // We can flip this credit position into a debit position, before hitting the target health.
                    // We have logic below that can determine health changes for debit positions. Rather than copy that here,
                    // fall through into it. But first we have to record the amount of tokens that are available as collateral
                    // and then adjust the effective collateral to reflect that it has come out
                    collateralTokenCount = trueCredit
                    effectiveCollateralAfterDeposit = effectiveCollateralAfterDeposit - collateralEffectiveValue
                    // NOTE: The above invalidates the healthAfterDeposit value, but it's not used below...
                }
            }

            // At this point, we're either dealing with a position that didn't have a credit balance in the withdraw
            // token, or we've accounted for the credit balance and adjusted the effective collateral above.

            // We can calculate the available debt increase that would bring us to the target health
            var availableDebtIncrease = (effectiveCollateralAfterDeposit / targetHealth) - effectiveDebtAfterDeposit

            let availableTokens = availableDebtIncrease * self.borrowFactor[withdrawType]! / self.priceOracle.price(token: withdrawType)

            return availableTokens + collateralTokenCount
        }

        // Returns the health the position would have if the given amount of the specified token were deposited.
        access(all) fun healthAfterDeposit(pid: UInt64, type: Type, amount: UFix64): UFix64 {
            let balanceSheet = self.positionBalanceSheet(pid: pid)
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!
            let tokenState = self.tokenState(type: type)

            var effectiveCollateralIncrease = 0.0
            var effectiveDebtDecrease = 0.0

            if position.balances[type] == nil || position.balances[type]!.direction == BalanceDirection.Credit {
                // Since the user has no debt in the given token, we can just compute how much
                // additional collateral this deposit will create.
                effectiveCollateralIncrease = amount * self.priceOracle.price(token: type) * self.collateralFactor[type]!
            } else {
                // The user has a debit position in the given token, we need to figure out if this deposit
                // will only pay off some of the debt, or if it will also create new collateral.
                let debtBalance = position.balances[type]!.scaledBalance
                let trueDebt = TidalProtocol.scaledBalanceToTrueBalance(
                    scaledBalance: debtBalance,
                    interestIndex: tokenState.debitInterestIndex
                )

                if trueDebt >= amount {
                    // This deposit will wipe out some or all of the debt, but won't create new collateral, we
                    // just need to account for the debt decrease.
                    effectiveDebtDecrease = amount * self.priceOracle.price(token: type) / self.borrowFactor[type]!
                } else {
                    // This deposit will wipe out all of the debt, and create new collateral.
                    effectiveDebtDecrease = trueDebt * self.priceOracle.price(token: type) / self.borrowFactor[type]!
                    effectiveCollateralIncrease = (amount - trueDebt) * self.priceOracle.price(token: type) * self.collateralFactor[type]!
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
        access(all) fun healthAfterWithdrawal(pid: UInt64, type: Type, amount: UFix64): UFix64 {
            let balanceSheet = self.positionBalanceSheet(pid: pid)
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!
            let tokenState = self.tokenState(type: type)

            var effectiveCollateralDecrease = 0.0
            var effectiveDebtIncrease = 0.0

            if position.balances[type] == nil || position.balances[type]!.direction == BalanceDirection.Debit {
                // The user has no credit position in the given token, we can just compute how much
                // additional effective debt this withdrawal will create.
                effectiveDebtIncrease = amount * self.priceOracle.price(token: type) / self.borrowFactor[type]!
            } else {
                // The user has a credit position in the given token, we need to figure out if this withdrawal
                // will only draw down some of the collateral, or if it will also create new debt.
                let creditBalance = position.balances[type]!.scaledBalance
                let trueCredit = TidalProtocol.scaledBalanceToTrueBalance(
                    scaledBalance: creditBalance,
                    interestIndex: tokenState.creditInterestIndex
                )

                if trueCredit >= amount {
                    // This withdrawal will draw down some collateral, but won't create new debt, we
                    // just need to account for the collateral decrease.
                    effectiveCollateralDecrease = amount * self.priceOracle.price(token: type) * self.collateralFactor[type]!
                } else {
                    // The withdrawal will wipe out all of the collateral, and create new debt.
                    effectiveDebtIncrease = (amount - trueCredit) * self.priceOracle.price(token: type) / self.borrowFactor[type]!
                    effectiveCollateralDecrease = trueCredit * self.priceOracle.price(token: type) * self.collateralFactor[type]!
                }
            }

            return TidalProtocol.healthComputation(
                effectiveCollateral: balanceSheet.effectiveCollateral - effectiveCollateralDecrease,
                effectiveDebt: balanceSheet.effectiveDebt + effectiveDebtIncrease
            )
        }

        // RESTORED: Async update infrastructure from Dieter's implementation
        access(EImplementation) fun asyncUpdate() {
            // TODO: In the production version, this function should only process some positions (limited by positionsProcessedPerCallback) AND
            // it should schedule each update to run in its own callback, so a revert() call from one update (for example, if a source or
            // sink aborts) won't prevent other positions from being updated.
            var processed: UInt64 = 0
            while self.positionsNeedingUpdates.length > 0 && processed < self.positionsProcessedPerCallback {
                let pid = self.positionsNeedingUpdates.removeFirst()
                self.asyncUpdatePosition(pid: pid)
                self.queuePositionForUpdateIfNecessary(pid: pid)
                processed = processed + 1
            }
        }

        // RESTORED: Async position update from Dieter's implementation
        access(EImplementation) fun asyncUpdatePosition(pid: UInt64) {
            let position = (&self.positions[pid] as auth(EImplementation) &InternalPosition?)!

            // First check queued deposits, their addition could affect the rebalance we attempt later
            for depositType in position.queuedDeposits.keys {
                let queuedVault <- position.queuedDeposits.remove(key: depositType)!
                let queuedAmount = queuedVault.balance
                let depositTokenState = self.tokenState(type: depositType)
                
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
    }

    access(all) struct Position {
        access(self) let id: UInt64
        access(self) let pool: Capability<auth(EPosition) &Pool>

        // Returns the balances (both positive and negative) for all tokens in this position.
        access(all) fun getBalances(): [PositionBalance] {
            let pool = self.pool.borrow()!
            return pool.getPositionDetails(pid: self.id).balances
        }

        // Returns the maximum amount of the given token type that could be withdrawn from this position.
        access(all) fun getAvailableBalance(type: Type): UFix64 {
            let pool = self.pool.borrow()!
            return pool.availableBalance(pid: self.id, type: type, pullFromTopUpSource: false)
        }

        // RESTORED: Enhanced available balance from Dieter's implementation
        access(all) fun availableBalance(type: Type, pullFromTopUpSource: Bool): UFix64 {
            let pool = self.pool.borrow()!
            return pool.availableBalance(pid: self.id, type: type, pullFromTopUpSource: pullFromTopUpSource)
        }

        // RESTORED: Health functions from Dieter's implementation
        access(all) fun getHealth(): UFix64 {
            let pool = self.pool.borrow()!
            return pool.positionHealth(pid: self.id)
        }

        access(all) fun getTargetHealth(): UFix64 {
            // DIETER'S DESIGN: Position is just a relay struct, return 0.0
            return 0.0
        }

        access(all) fun setTargetHealth(targetHealth: UFix64) {
            // DIETER'S DESIGN: Position is just a relay struct, do nothing
        }

        access(all) fun getMinHealth(): UFix64 {
            // DIETER'S DESIGN: Position is just a relay struct, return 0.0
            return 0.0
        }

        access(all) fun setMinHealth(minHealth: UFix64) {
            // DIETER'S DESIGN: Position is just a relay struct, do nothing
        }

        access(all) fun getMaxHealth(): UFix64 {
            // DIETER'S DESIGN: Position is just a relay struct, return 0.0
            return 0.0
        }

        access(all) fun setMaxHealth(maxHealth: UFix64) {
            // DIETER'S DESIGN: Position is just a relay struct, do nothing
        }

        // Returns the maximum amount of the given token type that could be deposited into this position.
        access(all) fun getDepositCapacity(type: Type): UFix64 {
            // There's no limit on deposits from the position's perspective
            return UFix64.max
        }

        // RESTORED: Simple deposit that calls depositAndPush with pushToDrawDownSink = false
        access(all) fun deposit(from: @{FungibleToken.Vault}) {
            let pool = self.pool.borrow()!
            pool.depositAndPush(pid: self.id, from: <-from, pushToDrawDownSink: false)
        }

        // RESTORED: Enhanced deposit from Dieter's implementation
        access(all) fun depositAndPush(from: @{FungibleToken.Vault}, pushToDrawDownSink: Bool) {
            let pool = self.pool.borrow()!
            pool.depositAndPush(pid: self.id, from: <-from, pushToDrawDownSink: pushToDrawDownSink)
        }

        // RESTORED: Simple withdraw that calls withdrawAndPull with pullFromTopUpSource = false
        access(all) fun withdraw(type: Type, amount: UFix64): @{FungibleToken.Vault} {
            return <- self.withdrawAndPull(type: type, amount: amount, pullFromTopUpSource: false)
        }

        // RESTORED: Enhanced withdraw from Dieter's implementation
        access(all) fun withdrawAndPull(type: Type, amount: UFix64, pullFromTopUpSource: Bool): @{FungibleToken.Vault} {
            let pool = self.pool.borrow()!
            return <- pool.withdrawAndPull(pid: self.id, type: type, amount: amount, pullFromTopUpSource: pullFromTopUpSource)
        }

        // Returns a NEW sink for the given token type that will accept deposits of that token and
        // update the position's collateral and/or debt accordingly. Note that calling this method multiple
        // times will create multiple sinks, each of which will continue to work regardless of how many
        // other sinks have been created.
        access(all) fun createSink(type: Type): {DFB.Sink} {
            // RESTORED: Create enhanced sink with pushToDrawDownSink option
            return self.createSinkWithOptions(type: type, pushToDrawDownSink: false)
        }

        // RESTORED: Enhanced sink creation from Dieter's implementation
        access(all) fun createSinkWithOptions(type: Type, pushToDrawDownSink: Bool): {DFB.Sink} {
            let pool = self.pool.borrow()!
            return PositionSink(id: self.id, pool: self.pool, type: type, pushToDrawDownSink: pushToDrawDownSink)
        }

        // Returns a NEW source for the given token type that will service withdrawals of that token and
        // update the position's collateral and/or debt accordingly. Note that calling this method multiple
        // times will create multiple sources, each of which will continue to work regardless of how many
        // other sources have been created.
        access(all) fun createSource(type: Type): {DFB.Source} {
            // RESTORED: Create enhanced source with pullFromTopUpSource option
            return self.createSourceWithOptions(type: type, pullFromTopUpSource: false)
        }

        // RESTORED: Enhanced source creation from Dieter's implementation
        access(all) fun createSourceWithOptions(type: Type, pullFromTopUpSource: Bool): {DFB.Source} {
            let pool = self.pool.borrow()!
            return PositionSource(id: self.id, pool: self.pool, type: type, pullFromTopUpSource: pullFromTopUpSource)
        }

        // RESTORED: Provider functions implementation from Dieter's design
        // Provides a sink to the Position that will have tokens proactively pushed into it when the
        // position has excess collateral. (Remember that sinks do NOT have to accept all tokens provided
        // to them; the sink can choose to accept only some (or none) of the tokens provided, leaving the position
        // overcollateralized.)
        //
        // Each position can have only one sink, and the sink must accept the default token type
        // configured for the pool. Providing a new sink will replace the existing sink. Pass nil
        // to configure the position to not push tokens.
        access(all) fun provideSink(sink: {DFB.Sink}?) {
            let pool = self.pool.borrow()!
            pool.provideDrawDownSink(pid: self.id, sink: sink)
        }

        // Provides a source to the Position that will have tokens proactively pulled from it when the
        // position has insufficient collateral. If the source can cover the position's debt, the position
        // will not be liquidated.
        //
        // Each position can have only one source, and the source must accept the default token type
        // configured for the pool. Providing a new source will replace the existing source. Pass nil
        // to configure the position to not pull tokens.
        access(all) fun provideSource(source: {DFB.Source}?) {
            let pool = self.pool.borrow()!
            pool.provideTopUpSource(pid: self.id, source: source)
        }

        init(id: UInt64, pool: Capability<auth(EPosition) & Pool>) {
            self.id = id
            self.pool = pool
        }
    }

    // CHANGE: Removed FlowToken-specific implementation
    // Helper for unit-tests – creates a new Pool with a generic default token
    // Tests should specify the actual token type they want to use
    access(all) fun createTestPool(defaultTokenThreshold: UFix64): @Pool {
        // For backward compatibility, we'll panic here
        // Tests should use createPool with explicit token type
        panic("Use createPool with explicit token type instead")
    }

    // CHANGE: Removed - tests should use proper token minting
    // This function is kept for backward compatibility but will panic
    access(all) fun createTestVault(balance: UFix64): @{FungibleToken.Vault} {
        panic("Use proper token minting instead of createTestVault")
    }

    // CHANGE: Add a proper pool creation function for tests
    access(all) fun createPool(defaultToken: Type, priceOracle: {DFB.PriceOracle}): @Pool {
        return <- create Pool(defaultToken: defaultToken, priceOracle: priceOracle)
    }

    // RESTORED: Helper function to create a test pool with dummy oracle
    access(all) fun createTestPoolWithOracle(defaultToken: Type): @Pool {
        let oracle = DummyPriceOracle(defaultToken: defaultToken)
        return <- create Pool(defaultToken: defaultToken, priceOracle: oracle)
    }

    // Helper for unit-tests - initializes a pool with a vault containing the specified balance
    access(all) fun createTestPoolWithBalance(defaultTokenThreshold: UFix64, initialBalance: UFix64): @Pool {
        // CHANGE: This function is deprecated - tests should create pools with explicit token types
        panic("Use createPool with explicit token type and deposit tokens separately")
    }

    // Events are now handled by FungibleToken standard
    // Total supply tracking
    access(all) var totalSupply: UFix64

    // Storage paths
    access(all) let VaultStoragePath: StoragePath
    access(all) let VaultPublicPath: PublicPath
    access(all) let ReceiverPublicPath: PublicPath
    access(all) let AdminStoragePath: StoragePath

    // FungibleToken contract interface requirement
    access(all) fun createEmptyVault(vaultType: Type): @{FungibleToken.Vault} {
        // CHANGE: This contract doesn't create vaults - it's a lending protocol
        panic("TidalProtocol doesn't create vaults - use the token's contract")
    }

    // ViewResolver conformance for metadata
    access(all) view fun getContractViews(resourceType: Type?): [Type] {
        return [
            Type<FungibleTokenMetadataViews.FTView>(),
            Type<FungibleTokenMetadataViews.FTDisplay>(),
            Type<FungibleTokenMetadataViews.FTVaultData>(),
            Type<FungibleTokenMetadataViews.TotalSupply>()
        ]
    }

    access(all) fun resolveContractView(resourceType: Type?, viewType: Type): AnyStruct? {
        switch viewType {
            case Type<FungibleTokenMetadataViews.FTView>():
                return FungibleTokenMetadataViews.FTView(
                    ftDisplay: self.resolveContractView(resourceType: nil, viewType: Type<FungibleTokenMetadataViews.FTDisplay>()) as! FungibleTokenMetadataViews.FTDisplay?,
                    ftVaultData: self.resolveContractView(resourceType: nil, viewType: Type<FungibleTokenMetadataViews.FTVaultData>()) as! FungibleTokenMetadataViews.FTVaultData?
                )
            case Type<FungibleTokenMetadataViews.FTDisplay>():
                let media = MetadataViews.Media(
                    file: MetadataViews.HTTPFile(
                        url: "https://example.com/TidalProtocol-logo.svg"
                    ),
                    mediaType: "image/svg+xml"
                )
                return FungibleTokenMetadataViews.FTDisplay(
                    name: "TidalProtocol Token",
                    symbol: "ALPF",
                    description: "TidalProtocol is a decentralized lending protocol on Flow blockchain",
                    externalURL: MetadataViews.ExternalURL("https://TidalProtocol.com"),
                    logos: MetadataViews.Medias([media]),
                    socials: {
                        "twitter": MetadataViews.ExternalURL("https://twitter.com/TidalProtocol")
                    }
                )
            case Type<FungibleTokenMetadataViews.FTVaultData>():
                return FungibleTokenMetadataViews.FTVaultData(
                    storagePath: self.VaultStoragePath,
                    receiverPath: self.ReceiverPublicPath,
                    metadataPath: self.VaultPublicPath,
                    receiverLinkedType: Type<&{FungibleToken.Receiver}>(),
                    metadataLinkedType: Type<&{FungibleToken.Balance, ViewResolver.Resolver}>(),
                    createEmptyVaultFunction: (fun(): @{FungibleToken.Vault} {
                        // CHANGE: TidalProtocol doesn't create vaults
                        panic("TidalProtocol doesn't create vaults")
                    })
                )
            case Type<FungibleTokenMetadataViews.TotalSupply>():
                return FungibleTokenMetadataViews.TotalSupply(
                    totalSupply: TidalProtocol.totalSupply
                )
        }
        return nil
    }

    // DFB.Sink implementation for TidalProtocol
    access(all) struct TidalProtocolSink: DFB.Sink {
        access(contract) let uniqueID: {DFB.UniqueIdentifier}?
        access(contract) let pool: auth(EPosition) &Pool
        access(contract) let positionID: UInt64
        
        access(all) view fun getSinkType(): Type {
            // CHANGE: For now, return a generic FungibleToken.Vault type
            // The actual type depends on what tokens the pool accepts
            return Type<@{FungibleToken.Vault}>()
        }

        access(all) fun minimumCapacity(): UFix64 {
            // For now, return 0 as there's no minimum
            return 0.0
        }

        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            let amount = from.balance
            if amount > 0.0 {
                let vault <- from.withdraw(amount: amount)
                self.pool.deposit(pid: self.positionID, funds: <-vault)
            }
        }
        
        init(pool: auth(EPosition) &Pool, positionID: UInt64) {
            self.uniqueID = nil
            self.pool = pool
            self.positionID = positionID
        }
    }

    // DFB.Source implementation for TidalProtocol
    access(all) struct TidalProtocolSource: DFB.Source {
        access(contract) let uniqueID: {DFB.UniqueIdentifier}?
        access(contract) let pool: auth(EPosition) &Pool
        access(contract) let positionID: UInt64
        access(contract) let tokenType: Type
        
        access(all) view fun getSourceType(): Type {
            return self.tokenType
        }

        access(all) fun minimumAvailable(): UFix64 {
            // Return the available balance for withdrawal
            let position = self.pool.getPositionDetails(pid: self.positionID)
            for balance in position.balances {
                if balance.type == self.tokenType && balance.direction == BalanceDirection.Credit {
                    return balance.balance
                }
            }
            return 0.0
        }

        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            let available = self.minimumAvailable()
            let withdrawAmount = available < maxAmount ? available : maxAmount
            if withdrawAmount > 0.0 {
                return <- self.pool.withdraw(pid: self.positionID, amount: withdrawAmount, type: self.tokenType)
            } else {
                // Create an empty vault by getting one from the pool's reserves
                // For now, just panic as we can't create empty vaults directly
                panic("Cannot create empty vault for type: ".concat(self.tokenType.identifier))
            }
        }
        
        init(pool: auth(EPosition) &Pool, positionID: UInt64, tokenType: Type) {
            self.uniqueID = nil
            self.pool = pool
            self.positionID = positionID
            self.tokenType = tokenType
        }
    }

    // RESTORED: Enhanced position sink from Dieter's implementation
    access(all) struct PositionSink: DFB.Sink {
        access(contract) let uniqueID: {DFB.UniqueIdentifier}?
        access(self) let pool: Capability<auth(EPosition) &Pool>
        access(self) let id: UInt64
        access(self) let type: Type
        access(self) let pushToDrawDownSink: Bool

        access(all) view fun getSinkType(): Type {
            return self.type
        }

        access(all) fun minimumCapacity(): UFix64 {
            // A position object has no limit to deposits
            return UFix64.max
        }
        
        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            let pool = self.pool.borrow()!
            pool.depositAndPush(pid: self.id, from: <-from.withdraw(amount: from.balance), pushToDrawDownSink: self.pushToDrawDownSink)
        }

        init(id: UInt64, pool: Capability<auth(EPosition) &Pool>, type: Type, pushToDrawDownSink: Bool) {
            self.uniqueID = nil
            self.id = id
            self.pool = pool
            self.type = type
            self.pushToDrawDownSink = pushToDrawDownSink
        }
    }

    // RESTORED: Enhanced position source from Dieter's implementation
    access(all) struct PositionSource: DFB.Source { 
        access(contract) let uniqueID: {DFB.UniqueIdentifier}?
        access(all) let pool: Capability<auth(EPosition) &Pool>
        access(all) let id: UInt64
        access(all) let type: Type
        access(all) let pullFromTopUpSource: Bool

        access(all) view fun getSourceType(): Type {
            return self.type
        }

        access(all) fun minimumAvailable(): UFix64 {
            let pool = self.pool.borrow()!
            return pool.availableBalance(pid: self.id, type: self.type, pullFromTopUpSource: self.pullFromTopUpSource)
        }

        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            let pool = self.pool.borrow()!
            let available = pool.availableBalance(pid: self.id, type: self.type, pullFromTopUpSource: self.pullFromTopUpSource)
            let withdrawAmount = (available > maxAmount) ? maxAmount : available
            if withdrawAmount > 0.0 {
                return <- pool.withdrawAndPull(pid: self.id, type: self.type, amount: withdrawAmount, pullFromTopUpSource: self.pullFromTopUpSource)
            } else {
                // Create an empty vault - this is a limitation we need to handle properly
                panic("Cannot create empty vault for type: ".concat(self.type.identifier))
            }
        }

        init(id: UInt64, pool: Capability<auth(EPosition) &Pool>, type: Type, pullFromTopUpSource: Bool) {
            self.uniqueID = nil
            self.id = id
            self.pool = pool
            self.type = type
            self.pullFromTopUpSource = pullFromTopUpSource
        }
    }

    // TidalProtocol starts here!

    access(all) enum BalanceDirection: UInt8 {
        access(all) case Credit
        access(all) case Debit
    }

    // RESTORED: DummyPriceOracle for testing from Dieter's design pattern
    access(all) struct DummyPriceOracle: PriceOracle {
        access(self) var prices: {Type: UFix64}
        access(self) let defaultToken: Type
        
        access(all) view fun unitOfAccount(): Type {
            return self.defaultToken
        }
        
        access(all) fun price(token: Type): UFix64 {
            return self.prices[token] ?? 1.0
        }
        
        access(all) fun setPrice(token: Type, price: UFix64) {
            self.prices[token] = price
        }
        
        init(defaultToken: Type) {
            self.defaultToken = defaultToken
            self.prices = {defaultToken: 1.0}
        }
    }

    // A structure returned externally to report a position's balance for a particular token.
    // This structure is NOT used internally.
    access(all) struct PositionBalance {
        access(all) let type: Type
        access(all) let direction: BalanceDirection
        access(all) let balance: UFix64

        init(type: Type, direction: BalanceDirection, balance: UFix64) {
            self.type = type
            self.direction = direction
            self.balance = balance
        }
    }

    // A structure returned externally to report all of the details associated with a position.
    // This structure is NOT used internally.
    access(all) struct PositionDetails {
        access(all) let balances: [PositionBalance]
        access(all) let poolDefaultToken: Type
        access(all) let defaultTokenAvailableBalance: UFix64
        access(all) let health: UFix64

        init(balances: [PositionBalance], poolDefaultToken: Type, defaultTokenAvailableBalance: UFix64, health: UFix64) {
            self.balances = balances
            self.poolDefaultToken = poolDefaultToken
            self.defaultTokenAvailableBalance = defaultTokenAvailableBalance
            self.health = health
        }
    }

    init() {
        // Initialize total supply
        self.totalSupply = 0.0
        
        // Set up storage paths
        self.VaultStoragePath = /storage/TidalProtocolVault
        self.VaultPublicPath = /public/TidalProtocolVault
        self.ReceiverPublicPath = /public/TidalProtocolReceiver
        self.AdminStoragePath = /storage/TidalProtocolAdmin
    }
}