/// Initial Draft of the Protocol, here for posterity.

/// Not to be used in any form other than as a reference for the original design of the protocol, and the thought process behind it.
/// This code is NOT intended to be functional, and should not be used as a basis for any implementation without significant modifications.

access(all) contract AlpenFlow {

    access(all) resource interface Vault {
        access(all) var balance: UFix64
        access(all) fun deposit(from: @{Vault})
        access(Withdraw) fun withdraw(amount: UFix64): @{Vault}
    }

    access(all) entitlement Withdraw

    access(all) resource FlowVault: Vault {
        access(all) var balance: UFix64

        access(all) fun deposit(from: @{Vault}) {
            destroy from
        }

        access(Withdraw) fun withdraw(amount: UFix64): @{Vault} {
            return <- create FlowVault()
        }

        init() {
            self.balance = 0.0
        }
    }

    access(all) struct interface Sink {
        access(all) view fun sinkType(): Type
        access(all) fun availableCapacity(): UFix64
        access(all) fun depositAvailable(from: auth(Withdraw) &{Vault})
    }

    access(all) struct interface Source {
        access(all) view fun sourceType(): Type
        access(all) fun availableBalance(): UFix64
        access(all) fun withdrawAvailable(maxAmount: UFix64): @{Vault}
    }

    access(all) struct interface PriceOracle {
        access(all) view fun unitOfAccount(): Type
        access(all) fun price(token: Type): UFix64
    }

    access(all) struct interface Flasher {
        access(all) view fun borrowType(): Type
        access(all) fun flashLoan(amount: UFix64, sink: {Sink}, source: {Source}): UFix64
    }

    access(all) struct interface SwapQuote {
        access(all) let amountIn: UFix64
        access(all) let amountOut: UFix64
    }

    access(all) struct interface Swapper {
        access(all) view fun inType(): Type
        access(all) view fun outType(): Type
        access(all) fun quoteIn(outAmount: UFix64): {SwapQuote}
        access(all) fun quoteOut(inAmount: UFix64): {SwapQuote}
        access(all) fun swap(inVault: @{Vault}, quote:{SwapQuote}?): @{Vault}
        access(all) fun swapBack(residual: @{Vault}, quote:{SwapQuote}): @{Vault}
    }

    access(all) struct SwapSink: Sink {
        access(self) let swapper: {Swapper}
        access(self) let sink: {Sink}

        init(swapper: {Swapper}, sink: {Sink}) {
            pre {
                swapper.outType() == sink.sinkType()
            }

            self.swapper = swapper
            self.sink = sink
        }

        access(all) view fun sinkType(): Type {
            return self.swapper.inType()
        }

        access(all) fun availableCapacity(): UFix64 {
            return self.swapper.quoteIn(outAmount: self.sink.availableCapacity()).amountIn
        }

        access(all) fun depositAvailable(from: auth(Withdraw) &{Vault}) {
            let limit = self.sink.availableCapacity()

            let swapQuote = self.swapper.quoteIn(outAmount: limit)
            let sinkLimit = swapQuote.amountIn
            let swapVault <- from.withdraw(amount: 0.0)

            if sinkLimit < swapVault.balance {
                // The sink is limited to fewer tokens that we have available. Only swap
                // the amount we need to meet the sink limit.
                swapVault.deposit(from: <-from.withdraw(amount: sinkLimit))
            }
            else {
                // The sink can accept all of the available tokens, so we swap everything
                swapVault.deposit(from: <-from.withdraw(amount: from.balance))
            }

            let swappedTokens <- self.swapper.swap(inVault: <-swapVault, quote: swapQuote)
            self.sink.depositAvailable(from: &swappedTokens as auth(Withdraw) &{Vault})

            if swappedTokens.balance > 0.0 {
                from.deposit(from: <-self.swapper.swapBack(residual: <-swappedTokens, quote: swapQuote))
            } else {
                destroy swappedTokens
            }
        }
    }

    // AlpenFlow starts here!

    access(all) enum BalanceDirection: UInt8 {
        access(all) case Credit
        access(all) case Debit
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


    access(all) entitlement EPosition
    access(all) entitlement EGovernance
    access(all) entitlement EImplementation

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

        view init() {
            self.direction = BalanceDirection.Credit
            self.scaledBalance = 0.0
        }

        access(all) fun copy(): InternalBalance {
            return self
        }

        access(all) fun recordDeposit(amount: UFix64, tokenState: auth(EImplementation) &TokenState) {
            if self.direction == BalanceDirection.Credit {
                // Depositing into a credit position just increases the balance.

                // To maximize precision, we could convert the scaled balance to a true balance, add the
                // deposit amount, and then convert the result back to a scaled balance. However, this will
                // only cause problems for very small deposits (fractions of a cent), so we save computational
                // cycles by just scaling the deposit amount and adding it directly to the scaled balance.
                let scaledDeposit = AlpenFlow.trueBalanceToScaledBalance(trueBalance: amount,
                    interestIndex: tokenState.creditInterestIndex)

                self.scaledBalance = self.scaledBalance + scaledDeposit

                // Increase the total credit balance for the token
                tokenState.updateCreditBalance(amount: Fix64(amount))
            } else {
                // When depositing into a debit position, we first need to compute the true balance to see
                // if this deposit will flip the position from debit to credit.
                let trueBalance = AlpenFlow.scaledBalanceToTrueBalance(scaledBalance: self.scaledBalance,
                    interestIndex: tokenState.debitInterestIndex)

                if trueBalance > amount {
                    // The deposit isn't big enough to clear the debt, so we just decrement the debt.
                    let updatedBalance = trueBalance - amount

                    self.scaledBalance = AlpenFlow.trueBalanceToScaledBalance(trueBalance: updatedBalance,
                        interestIndex: tokenState.debitInterestIndex)

                    // Decrease the total debit balance for the token
                    tokenState.updateDebitBalance(amount: -1.0 * Fix64(amount))
                } else {
                    // The deposit is enough to clear the debt, so we switch to a credit position.
                    let updatedBalance = amount - trueBalance

                    self.direction = BalanceDirection.Credit
                    self.scaledBalance = AlpenFlow.trueBalanceToScaledBalance(trueBalance: updatedBalance,
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
                let scaledWithdrawal = AlpenFlow.trueBalanceToScaledBalance(trueBalance: amount,
                    interestIndex: tokenState.debitInterestIndex)

                self.scaledBalance = self.scaledBalance + scaledWithdrawal

                // Increase the total debit balance for the token
                tokenState.updateDebitBalance(amount: Fix64(amount))
            } else {
                // When withdrawing from a credit position, we first need to compute the true balance to see
                // if this withdrawal will flip the position from credit to debit.
                let trueBalance = AlpenFlow.scaledBalanceToTrueBalance(scaledBalance: self.scaledBalance,
                    interestIndex: tokenState.creditInterestIndex)

                if trueBalance >= amount {
                    // The withdrawal isn't big enough to push the position into debt, so we just decrement the
                    // credit balance.
                    let updatedBalance = trueBalance - amount

                    self.scaledBalance = AlpenFlow.trueBalanceToScaledBalance(trueBalance: updatedBalance,
                        interestIndex: tokenState.creditInterestIndex)

                    // Decrease the total credit balance for the token
                    tokenState.updateCreditBalance(amount: -1.0 * Fix64(amount))
                } else {
                    // The withdrawal is enough to push the position into debt, so we switch to a debit position.
                    let updatedBalance = amount - trueBalance

                    self.direction = BalanceDirection.Debit
                    self.scaledBalance = AlpenFlow.trueBalanceToScaledBalance(trueBalance: updatedBalance,
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
        EImplementation -> Withdraw
    }

    access(all) resource InternalPosition {
        access(mapping ImplementationUpdates) var balances: {Type: InternalBalance}
        access(mapping ImplementationUpdates) var queuedDeposits: @{Type: {Vault}}
        access(EImplementation) var targetHealth: UFix64
        access(EImplementation) var minHealth: UFix64
        access(EImplementation) var maxHealth: UFix64
        access(EImplementation) var drawDownSink: {Sink}?
        access(EImplementation) var topUpSource: {Source}?

        view init() {
            self.balances = {}
            self.queuedDeposits <- {}
            self.targetHealth = 1.3
            self.minHealth = 1.1
            self.maxHealth = 1.5
            self.drawDownSink = nil
            self.topUpSource = nil
        }

        access(EImplementation) fun setDrawDownSink(_ sink: {Sink}?) {
            self.drawDownSink = sink
        }

        access(EImplementation) fun setTopUpSource(_ source: {Source}?) {
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
    access(self) fun interestMul(_ a: UInt64, _ b: UInt64): UInt64 {
        let aScaled: UInt64 = a / 100000000
        let bScaled = b / 100000000

        return aScaled * bScaled
    }

    // Converts a yearly interest rate (as a UFix64) to a per-second multiplication factor
    // (stored in a UInt64 as a fixed point number with 16 decimal places). The input to this function will be
    // just the relative interest rate (e.g. 0.05 for 5% interest), but the result will be
    // the per-second multiplier (e.g. 1.000000000001).
    access(self) fun perSecondInterestRate(yearlyRate: UFix64): UInt64 {
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
    access(self) fun compoundInterestIndex(oldIndex: UInt64, perSecondRate: UInt64, elapsedSeconds: UFix64): UInt64 {
        var result = oldIndex
        var current = perSecondRate

        // Truncate the elapsed time to an integer number of seconds.
        var secondsCounter = UInt64(elapsedSeconds)

        while secondsCounter > 0 {
            if secondsCounter & 1 == 1 {
                result = AlpenFlow.interestMul(result, current)
            }
            current = AlpenFlow.interestMul(current, current)
            secondsCounter = secondsCounter >> 1
        }

        return result
    }

    access(self) fun scaledBalanceToTrueBalance(scaledBalance: UFix64, interestIndex: UInt64): UFix64 {
        // The interest index is essentially a fixed point number with 16 decimal places, we convert
        // it to a UFix64 by copying the byte representation, and then dividing by 10^8 (leaving an
        // additional 10^8 as required for the UFix64 representation).
        let indexMultiplier = UFix64.fromBigEndianBytes(interestIndex.toBigEndianBytes())! / 100000000.0
        return scaledBalance * indexMultiplier
    }

    access(self) fun trueBalanceToScaledBalance(trueBalance: UFix64, interestIndex: UInt64): UFix64 {
        // The interest index is essentially a fixed point number with 16 decimal places, we convert
        // it to a UFix64 by copying the byte representation, and then dividing by 10^8 (leaving and
        // additional 10^8 as required for the UFix64 representation).
        let indexMultiplier = UFix64.fromBigEndianBytes(interestIndex.toBigEndianBytes())! / 100000000.0
        return trueBalance / indexMultiplier
    }

    access(all) struct TokenState {
        access(all) var lastUpdateTime: UFix64
        access(all) var totalCreditBalance: UFix64
        access(all) var totalDebitBalance: UFix64
        access(all) var creditInterestIndex: UInt64
        access(all) var debitInterestIndex: UInt64
        access(all) var currentCreditRate: UInt64
        access(all) var currentDebitRate: UInt64
        access(all) var interestCurve: {InterestCurve}
        access(all) var depositRate: UFix64
        access(all) var depositCapacity: UFix64
        access(all) var depositCapacityCap: UFix64

        access(all) fun updateCreditBalance(amount: Fix64) {
            // temporary cast the credit balance to a signed value so we can add/subtract
            let adjustedBalance = Fix64(self.totalCreditBalance) + amount
            self.totalCreditBalance = UFix64(adjustedBalance)
            self.updateInterestRates()
        }

        access(all) fun updateDebitBalance(amount: Fix64) {
            // temporary cast the debit balance to a signed value so we can add/subtract
            let adjustedBalance = Fix64(self.totalDebitBalance) + amount
            self.totalDebitBalance = UFix64(adjustedBalance)
            self.updateInterestRates()
        }

        access(all) fun updateForTimeChange() {
            let currentTime = getCurrentBlock().timestamp
            let timeDelta = currentTime - self.lastUpdateTime

            if timeDelta > 0.0 {
                self.creditInterestIndex = AlpenFlow.compoundInterestIndex(oldIndex: self.creditInterestIndex, perSecondRate: self.currentCreditRate, elapsedSeconds: timeDelta)
                self.debitInterestIndex = AlpenFlow.compoundInterestIndex(oldIndex: self.debitInterestIndex, perSecondRate: self.currentDebitRate, elapsedSeconds: timeDelta)
                self.lastUpdateTime = currentTime

                let newDepositCapacity = self.depositCapacity + (self.depositRate * timeDelta)

                if newDepositCapacity >= self.depositCapacityCap {
                    self.depositCapacity = self.depositCapacityCap
                } else {
                    self.depositCapacity = newDepositCapacity
                }
            }
        }

        access(all) fun depositLimit(): UFix64 {
            // Each deposit is limited to 5% of the total deposit capacity, to ensure that we can
            // service dozens of deposits in a single block without meaningfully running out of
            // capacity.
            return self.depositCapacity * 0.05
        }

        access(self) fun updateInterestRates() {
            let debitRate = self.interestCurve.interestRate(creditBalance: self.totalCreditBalance, debitBalance: self.totalDebitBalance)
            let debitIncome = self.totalDebitBalance * (1.0 + debitRate)
            let insuranceAmount = self.totalCreditBalance * 0.001
            let creditRate = ((debitIncome - insuranceAmount) / self.totalCreditBalance) - 1.0
            self.currentCreditRate = AlpenFlow.perSecondInterestRate(yearlyRate: creditRate)
            self.currentDebitRate = AlpenFlow.perSecondInterestRate(yearlyRate: debitRate)
        }

        access(EImplementation) fun setInterestCurve(interestCurve: {InterestCurve}) {
            self.updateForTimeChange()
            self.interestCurve = interestCurve
            self.updateInterestRates()
        }

        init(interestCurve: {InterestCurve}, depositRate: UFix64, depositCapacityCap: UFix64) {
            self.lastUpdateTime = 0.0
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

    // A convenience function for computing a health value from effective collateral and debt values.
    // Most of the time, this is just effectiveCollateral / effectiveDebt, but we need to
    // handle the special cases where either value is zero, or where the debt is so small
    // relative to the collateral that it would cause an overflow.
    //
    // Returns 0.0 if there is no collateral, and UFix64.max if there is no debt, or the debt
    // is so small relative to the collateral that division would cause an overflow.
    access(all) fun healthComputation(effectiveCollateral: UFix64, effectiveDebt: UFix64): UFix64 {
        var health = 0.0

        if effectiveCollateral == 0.0 {
            health = 0.0
        } else if effectiveDebt == 0.0 {
            health = UFix64.max
        } else if (effectiveDebt / effectiveCollateral) == 0.0 {
            // If we get to this point, both debt and collateral are non-zero, if this
            // division rounds to zero, the debt is so small relative to the collateral
            // that the health is essentially infinite.
            // Two notes:
            //   - The division above is intentially opposite to the normal health
            //     computation (below). We are trying to catch the situation where the debt
            //     is very small relative to the collateral, and the normal division
            //     could overflow in that case. (For example, I have $1,000,000,000 in
            //     collateral, and $0.00000001 in debt.)
            //  - Huh! I seem to have forgotten the other thing... :thinking_face: 
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
            self.health = AlpenFlow.healthComputation(effectiveCollateral: effectiveCollateral, effectiveDebt: effectiveDebt)
        }
    }

    access(all) resource Pool {
        // A simple version number that is incremented whenever one or more interest indices
        // are updated. This is used to detect when the interest indices need to be updated in
        // InternalPositions.
        access(EImplementation) var version: UInt64

        // Global state for tracking each token
        access(self) var globalLedger: {Type: TokenState}
        
        // Individual user positions
        access(self) var positions: @{UInt64: InternalPosition}

        // The actual reserves of each token
        access(self) var reserves: @{Type: {Vault}}

        // The default token type used as the "unit of account" for the pool.
        access(self) let defaultToken: Type

        // A price oracle that will return the price of each token in terms of the default token.
        access(self) var priceOracle: {PriceOracle}

        access(EImplementation) var positionsNeedingUpdates: [UInt64]
        access(self) var positionsProcessedPerCallback: UInt64

        // These dictionaries determine borrowing limits. Each token has a collateral factor and a
        // borrow factor.
        //
        // When determining the total collateral amount that can be borrowed against, the value of the
        // token (as given by the oracle) is multiplied by the collateral factor. So, a token with a
        // collateral factor of 0.8 would only allow you to borrow 80% as much as if you had a the same
        // value of a token with a collateral factor of 1.0. The total "effective collateral" for a
        // position is the value of each token multiplied by it collateral factor.
        //
        // At the same time, the "borrow factor" determines if the user can borrow against all of that
        // effective collateral, or if they can only borrow a portion of it to manage risk.
        // When determining the health the a position, the total debt is DIVIDED by the borrow factor
        // to determine the maximum amount that can be borrowed.
        //
        // So, if a token has a borrow factor of 0.8, you can only borrow 80% as much as you could borrow
        // of a token with a borrow factor of 1.0.
        //
        // Prelaunch, our best guess for reasonable borrow and collateral factors are:
        //      Approved stables: (collateralFactor: 1.0, borrowFactor: 0.9)
        //      Established cryptos: (collateralFactor: 0.8, borrowFactor: 0.8)
        //      Speculative cryptos: (collateralFactor: 0.6, borrowFactor: 0.6)
        //      Native stable: (collateralFactor: 1.0, borrowFactor: 1.0)
        access(self) var collateralFactor: {Type: UFix64}
        access(self) var borrowFactor: {Type: UFix64}

        init(defaultToken: Type, priceOracle: {PriceOracle}) {
            pre {
                priceOracle.unitOfAccount() == defaultToken: "Price oracle must return prices in terms of the default token"
            }

            self.version = 0
            self.globalLedger = {}
            self.positions <- {}
            self.reserves <- {}
            self.defaultToken = defaultToken
            self.priceOracle = priceOracle
            self.collateralFactor = {defaultToken: 1.0}
            self.borrowFactor = {defaultToken: 1.0}
            self.positionsNeedingUpdates = []
            self.positionsProcessedPerCallback = 100
        }

        // Mark this position as needing an asynchronous update
        access(self) fun queuePositionForUpdateIfNecessary(pid: UInt64) {
            if self.positionsNeedingUpdates.contains(pid) {
                // If this position is already queued for an update, no need to check anything else
                return
            } else {
                // If this position is not already queued for an update, we need to check if it needs one

                // NOTE: Conceptually, the logic in this function is a "short circuit OR" evaluation. We
                //       structure it as a series of individual checks (with returns to manage the "short circuit")
                //       but by having each check as it's own section, we can keep things readable and not
                //       do any more computations than necessary. The fastest and/or most common conditions
                //       should come first where possible.
                let position = &self.positions[pid] as auth(EImplementation) &InternalPosition?!

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

        access(EPosition) fun provideDrawDownSink(pid: UInt64, sink: {Sink}?) {
            let position = &self.positions[pid] as auth(EImplementation) &InternalPosition?!
            position.setDrawDownSink(sink)
        }
            
        access(EPosition) fun provideTopUpSource(pid: UInt64, source: {Source}?) {
            let position = &self.positions[pid] as auth(EImplementation) &InternalPosition?!
            position.setTopUpSource(source)
        }

        // A convenience function that returns a reference to a particular token state, making sure
        // it's up-to-date for the passage of time. This should always be used when accessing a token
        // state to avoid missing interest updates (duplicate calls to updateForTimeChange() are a nop
        // within a single block).
        access(self) fun tokenState(type: Type): auth(EImplementation) &TokenState {
            let state = &self.globalLedger[type]! as auth(EImplementation) &TokenState

            state.updateForTimeChange()

            return state
        }

        // A public method that allows anyone to deposit funds into any position. AS A RULE this method
        // should not be avoided (use the deposit methods of the Position relay struct instead).
        // After all, it would be an easy bug to pass in the wrong value for position ID, and once those
        // funds are gone, they are gone.
        //
        // However, there may be some use cases where it's useful to deposit funds on behalf of another user
        // so we have this public method available for those cases.
        access(all) fun depositToPosition(pid: UInt64, from: @{Vault}) {
            self.depositAndPush(pid: pid, from: <-from, pushToDrawDownSink: false)
        }

        access(EPosition) fun depositAndPush(pid: UInt64, from: @{Vault}, pushToDrawDownSink: Bool) {
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
            let position = &self.positions[pid] as auth(EImplementation) &InternalPosition?!
            let tokenState = self.tokenState(type: type)

            // If the deposit amount is too big, we need to queue some of the deposit to be added later
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

            // Reflect the deposit in the position's balance
            position.balances[type]!.recordDeposit(amount: from.balance, tokenState: tokenState)

            // Add the money to the reserves
            let reserveVault = (&self.reserves[type] as auth(Withdraw) &{Vault}?)!
            reserveVault.deposit(from: <-from)

            if pushToDrawDownSink {
                self.rebalancePosition(pid: pid, force: true)
            }

            self.queuePositionForUpdateIfNecessary(pid: pid)
        }

        access(EPosition) fun withdrawAndPull(pid: UInt64, type: Type, amount: UFix64, pullFromTopUpSource: Bool): @{Vault} {
            pre {
                self.positions[pid] != nil: "Invalid position ID"
                self.globalLedger[type] != nil: "Invalid token type"
                amount > 0.0: "Withdrawal amount must be positive"
            }

            // Update the global interest indices on the affected token to reflect the passage of time.
            let tokenState = self.tokenState(type: type)

            // Preflight to see if the funds are available
            let position = &self.positions[pid] as auth(EImplementation) &InternalPosition?!
            let topUpSource = position.topUpSource
            let topUpType = topUpSource?.sourceType() ?? self.defaultToken

            let requiredDeposit = self.fundsRequiredForTargetHealthAfterWithdrawing(pid: pid, depositType: topUpType, targetHealth: position.minHealth,
                withdrawType: type, withdrawAmount: amount)

            var canWithdraw = false

            if requiredDeposit == 0.0 {
                // We can service this withdrawal without any top up
                canWithdraw = true
            } else {
                // We need more funds to service this withdrawal, see if they are available from the top up source
                if pullFromTopUpSource && topUpSource != nil {
                    // If we have to rebalance, let's try to rebalance to the target health, not just the minimum
                    let idealDeposit = self.fundsRequiredForTargetHealthAfterWithdrawing(pid: pid, depositType: type, targetHealth: position.targetHealth,
                            withdrawType: topUpType, withdrawAmount: amount)

                    let pulledVault <- topUpSource!.withdrawAvailable(maxAmount: idealDeposit)

                    // NOTE: We requested the "ideal" deposit, but we compare against the required deposit here.
                    // The top up source may not have enough funds get us to the target health, but could have
                    // enough to keep us over the minimum.
                    if pulledVault.balance >= requiredDeposit {
                        // We can service this withdrawal if we deposit funds from our top up source
                        self.depositAndPush(pid: pid, from: <-pulledVault, pushToDrawDownSink: false)
                        canWithdraw = true
                    } else {
                        // We can't get the funds required to service this withdrawal, so we just abort
                        panic("Insufficient funds for withdrawal")
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

            // Reflect the withdrawal in the position's balance
            position.balances[type]!.recordWithdrawal(amount: amount, tokenState: tokenState)

            // Belt and suspenders: This should never happen if the math above is correct, but let's be sure...
            assert(self.positionHealth(pid: pid) >= 1.0, message: "Position is overdrawn")

            self.queuePositionForUpdateIfNecessary(pid: pid)

            let reserveVault = (&self.reserves[type] as auth(Withdraw) &{Vault}?)!
            return <- reserveVault.withdraw(amount: amount)
        }

        access(self) fun positionBalanceSheet(pid: UInt64): BalanceSheet {
            let position = &self.positions[pid] as auth(EImplementation) &InternalPosition?!
            let priceOracle = &self.priceOracle as &{PriceOracle}

            // Get the position's collateral and debt values in terms of the default token.
            var effectiveCollateral = 0.0
            var effectiveDebt = 0.0

            for type in position.balances.keys {
                let balance = position.balances[type]!
                let tokenState = &self.globalLedger[type]! as auth(EImplementation) &TokenState
                if balance.direction == BalanceDirection.Credit {
                    let trueBalance = AlpenFlow.scaledBalanceToTrueBalance(scaledBalance: balance.scaledBalance,
                        interestIndex: tokenState.creditInterestIndex)
                    
                    let value = priceOracle.price(token: type) * trueBalance

                    effectiveCollateral = effectiveCollateral + (value * self.collateralFactor[type]!)
                } else {
                    let trueBalance = AlpenFlow.scaledBalanceToTrueBalance(scaledBalance: balance.scaledBalance,
                        interestIndex: tokenState.debitInterestIndex)

                    let value = priceOracle.price(token: type) * trueBalance

                    effectiveDebt = effectiveDebt + (value / self.borrowFactor[type]!)
                }
            }

            return BalanceSheet(effectiveCollateral: effectiveCollateral, effectiveDebt: effectiveDebt)
        }

        // Returns the health of the given position, which is the ratio of the position's effective collateral
        // to its debt (as denominated in the default token). ("Effective collateral" means the
        // value of each credit balance times the liquidation threshold for that token. i.e. the maximum borrowable amount)
        access(all) fun positionHealth(pid: UInt64): UFix64 {
            let balanceSheet = self.positionBalanceSheet(pid: pid)

            return balanceSheet.health
        }

        access(all) fun availableBalance(pid: UInt64, type: Type, pullFromTopUpSource: Bool): UFix64 {
            let position = &self.positions[pid] as auth(EImplementation) &InternalPosition?!

            if pullFromTopUpSource && position.topUpSource != nil {
               let topUpSource = position.topUpSource!
               let sourceType = topUpSource.sourceType()
               let sourceAmount = topUpSource.availableBalance()

               return self.fundsAvailableAboveTargetHealthAfterDepositing(pid: pid, withdrawType: type, targetHealth: position.minHealth,
                    depositType: sourceType, depositAmount: sourceAmount)
            } else {
                return self.fundsAvailableAboveTargetHealth(pid: pid, type: type, targetHealth: position.minHealth)
            }
        }

        // The quantity of funds of a specified token which would need to be deposited to bring the
        // position to the target health. This function will return 0.0 if the position is already at or over
        // that health value.
        access(all) fun fundsRequiredForTargetHealth(pid: UInt64, type: Type, targetHealth: UFix64): UFix64 {
            return self.fundsRequiredForTargetHealthAfterWithdrawing(pid: pid, depositType: type, targetHealth: targetHealth, 
                withdrawType: self.defaultToken, withdrawAmount: 0.0)
        }

        // The quantity of funds of a specified token which would need to be deposited to bring the
        // position to the target health assuming we also withdraw a specified amount of another
        // token. This function will return 0.0 if the position would already be at or over the target
        // health value after the proposed withdrawal.
        access(all) fun fundsRequiredForTargetHealthAfterWithdrawing(pid: UInt64, depositType: Type, targetHealth: UFix64,
                withdrawType: Type, withdrawAmount: UFix64): UFix64
        {
            if depositType == withdrawType && withdrawAmount > 0.0 {
                // If the deposit and withdrawal types are the same, we compute the required deposit assuming 
                // no withdrawal (which is less work) and increase that by the withdraw amount at the end
                return self.fundsRequiredForTargetHealth(pid: pid, type: depositType, targetHealth: targetHealth) + withdrawAmount
            }

            let balanceSheet = self.positionBalanceSheet(pid: pid)

            let position = &self.positions[pid] as auth(EImplementation) &InternalPosition?!

            var effectiveCollateralAfterWithdrawal = balanceSheet.effectiveCollateral
            var effectiveDebtAfterWithdrawal = balanceSheet.effectiveDebt

            if withdrawAmount != 0.0 {
                if position.balances[withdrawType] == nil || position.balances[withdrawType]!.direction == BalanceDirection.Debit {
                    // If the doesn't have any collateral for the withdrawn token, we can just compute how much
                    // additional effective debt the withdrawal will create.
                    effectiveDebtAfterWithdrawal = balanceSheet.effectiveDebt + (withdrawAmount * self.priceOracle.price(token: withdrawType) / self.borrowFactor[withdrawType]!)
                } else {
                    let withdrawTokenState = self.tokenState(type: withdrawType)

                    // The user has a collateral position in the given token, we need to figure out if this withdrawal
                    // will flip over into debt, or just draw down the collateral.
                    let collateralBalance = position.balances[depositType]!.scaledBalance
                    let trueCollateral = AlpenFlow.scaledBalanceToTrueBalance(scaledBalance: collateralBalance,
                        interestIndex: withdrawTokenState.creditInterestIndex)

                    if trueCollateral >= withdrawAmount {
                        // This withdrawal will draw down collateral, but won't create debt, we just need to account
                        // for the collateral decrease.
                        effectiveCollateralAfterWithdrawal = balanceSheet.effectiveCollateral - (withdrawAmount * self.priceOracle.price(token: depositType) * self.collateralFactor[depositType]!)
                    } else {
                        // The withdrawal will wipe out all of the collateral, and create some debt.
                        effectiveDebtAfterWithdrawal = balanceSheet.effectiveDebt +
                                ((withdrawAmount - trueCollateral) * self.priceOracle.price(token: withdrawType) / self.borrowFactor[withdrawType]!)

                        effectiveCollateralAfterWithdrawal = balanceSheet.effectiveCollateral -
                                (trueCollateral * self.priceOracle.price(token: depositType) * self.collateralFactor[depositType]!)
                    }
                }
            }

            // We now have new effective collateral and debt values that reflect the proposed withdrawal (if any!)
            // Now we can figure out how many of the given token would need to be deposited to bring the position
            // to the target health value.

            var healthAfterWithdrawal = AlpenFlow.healthComputation(effectiveCollateral: effectiveCollateralAfterWithdrawal, effectiveDebt: effectiveDebtAfterWithdrawal)

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
                let debtBalance = position.balances[depositType]!.scaledBalance
                let trueDebt = AlpenFlow.scaledBalanceToTrueBalance(scaledBalance: debtBalance,
                    interestIndex: depositTokenState.debitInterestIndex)
                let debtEffectiveValue = self.priceOracle.price(token: depositType) * trueDebt / self.borrowFactor[depositType]!

                var debtIsEnough = false

                if debtEffectiveValue == effectiveDebtAfterWithdrawal {
                    // This token is the only debt in the position, so we can DEFINITELY effect the requested health change
                    // just by paying off some of the debt.
                    debtIsEnough = true
                } else {
                    // Check what the new health would be if we paid off the entire debt.
                    let potentialHealth = AlpenFlow.healthComputation(effectiveCollateral:effectiveCollateralAfterWithdrawal,
                            effectiveDebt: (effectiveDebtAfterWithdrawal - debtEffectiveValue))

                    // Does debt payment alone bring the position up to the requested health?
                    if potentialHealth >= targetHealth {
                        debtIsEnough = true
                    }
                }

                if debtIsEnough {
                    // We can effect the requested health change just by paying off some of the deposit token's debt. We just need to work
                    // out how many units of the token would be needed to bring the position up by the requested amount.

                    // First determine the amount of debt to pay back in terms of the default token. This calculation is the result of
                    // solving the equation:
                    //
                    //   health + healthChange = effectiveCollateral / (effectiveDebt - requiredEffectiveValue)
                    //
                    // for requiredEffectiveValue, using the fact that health = effectiveCollateral / effectiveDebt.
                    // (H == health, dH == delta health, D = effective debt, dD = delta debt, C = effective collateral)
                    //
                    // H + dH = C / (D - dD)
                    // (H + dH) * (D - dD) = C
                    // H•D + dH•D - H•dD - dH•dD = C
                    //
                    // Subtract H•D = C from both sides:
                    // dH•D - H•dD - dH•dD = 0
                    // dH•D = H•dD + dH•dD
                    // Factor out dD:
                    // dH•D = dD * (H + dH)
                    // dD = (dH•D) / (H + dH)
                    let requiredHealthChange = targetHealth - healthAfterWithdrawal
                    let requiredEffectiveValue = (requiredHealthChange * effectiveDebtAfterWithdrawal) / targetHealth

                    // The amount of the token to pay back, in units of the token.
                    let requiredTokenCount = requiredEffectiveValue * self.borrowFactor[depositType]! / self.priceOracle.price(token: depositType)

                    return requiredTokenCount
                } else {
                    // We need to pay off more than just this token's debt to effect the requested health change.

                    // We have logic below that can determine health changes for credit positions. Rather than copy that here,
                    // fall through into it. But first we have to record the amount of tokens that went to the debt in
                    // debtTokenCount, and then adjust the effective debt to reflect that repayment
                    debtTokenCount = trueDebt
                    effectiveDebtAfterWithdrawal = effectiveDebtAfterWithdrawal - debtEffectiveValue
                    healthAfterWithdrawal = AlpenFlow.healthComputation(effectiveCollateral: effectiveCollateralAfterWithdrawal,
                            effectiveDebt: effectiveDebtAfterWithdrawal)
                }
            }

            // At this point, we're either dealing with a position that already had a credit balance (possibly zero!) in
            // the deposit token, or we simulated paying off all of the positions' debt in the deposit token and adjusted
            // the effective debt to account for that.

            // Computing the amount of collateral needed for a health change is very simple. We just need to
            // multiply the required health change by the effective debt, and turn that into a token amount.
            let healthChange = targetHealth - healthAfterWithdrawal
            let requiredEffectiveCollateral = healthChange * effectiveDebtAfterWithdrawal

            // The amount of the token to pay back, in units of the token.
            let collateralTokenCount = requiredEffectiveCollateral / self.priceOracle.price(token: depositType) / self.borrowFactor[depositType]!

            // debtTokenCount is the number of tokens that went towards debt, zero if there was no debt.
            return collateralTokenCount + debtTokenCount
        }

        // Returns the quantity of the specified token that could be withdraw while still keeping the position's health
        // at or above the provided target.
        access(all) fun fundsAvailableAboveTargetHealth(pid: UInt64, type: Type, targetHealth: UFix64): UFix64 {
            return self.fundsAvailableAboveTargetHealthAfterDepositing(pid: pid, withdrawType: type, targetHealth: targetHealth,
                depositType: self.defaultToken, depositAmount: 0.0)
        }


        // Returns the quantity of the specified token that could be withdraw while still keeping the position's health
        // at or above the provided target.
        access(all) fun fundsAvailableAboveTargetHealthAfterDepositing(pid: UInt64, withdrawType: Type, targetHealth: UFix64,
                depositType: Type, depositAmount: UFix64): UFix64
        {
            if depositType == withdrawType && depositAmount > 0.0 {
                // If the deposit and withdrawal types are the same, we compute the required deposit assuming 
                // no deposit (which is less work) and increase that by the deposit amount at the end
                return self.fundsAvailableAboveTargetHealth(pid: pid, type: withdrawType, targetHealth: targetHealth) + depositAmount
            }

            let balanceSheet = self.positionBalanceSheet(pid: pid)

            let position = &self.positions[pid] as auth(EImplementation) &InternalPosition?!

            var effectiveCollateralAfterDeposit = balanceSheet.effectiveCollateral
            var effectiveDebtAfterDeposit = balanceSheet.effectiveDebt

            if depositAmount != 0.0 {
                if position.balances[withdrawType] == nil || position.balances[withdrawType]!.direction == BalanceDirection.Debit {
                    // If there's no debt for the deposit token, we can just compute how much additional effective collateral the deposit will create.
                    effectiveCollateralAfterDeposit = balanceSheet.effectiveCollateral + (depositAmount * self.priceOracle.price(token: depositType) * self.collateralFactor[depositType]!)
                } else {
                    let depositTokenState = self.tokenState(type: depositType)

                    // The user has a debt position in the given token, we need to figure out if this deposit
                    // will result in net collateral, or just bring down the debt.
                    let debtBalance = position.balances[depositType]!.scaledBalance
                    let trueDebt = AlpenFlow.scaledBalanceToTrueBalance(scaledBalance: debtBalance,
                        interestIndex: depositTokenState.debitInterestIndex)

                    if trueDebt >= depositAmount {
                        // This deposit will pay down some debt, but won't result in net collateral, we just need to account
                        // for the debt decrease.
                        effectiveDebtAfterDeposit = balanceSheet.effectiveDebt - (depositAmount * self.priceOracle.price(token: depositType) / self.collateralFactor[depositType]!)
                    } else {
                        // The depoist will wipe out all of the debt, and create some collaterol.
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
            var healthAfterDeposit = AlpenFlow.healthComputation(effectiveCollateral: effectiveCollateralAfterDeposit, effectiveDebt: effectiveDebtAfterDeposit)

            if healthAfterDeposit <= targetHealth {
                // The position is already at or below the target health, so we can't withdraw anything.
                return 0.0
            }

            // For situations where the available withdrawal will BOTH draw down collateral and create debt, we keep
            // track of the number of tokens are available from collateral
            var collateralTokenCount = 0.0

            if position.balances[withdrawType] != nil && position.balances[withdrawType]!.direction == BalanceDirection.Credit {
                // The user has a credit position in the withdraw token, we start by looking at the health impact of pulling out all
                // of that collateral
                let withdrawTokenState = self.tokenState(type: withdrawType)
                let creditBalance = position.balances[depositType]!.scaledBalance
                let trueCredit = AlpenFlow.scaledBalanceToTrueBalance(scaledBalance: creditBalance,
                    interestIndex: withdrawTokenState.creditInterestIndex)
                let collateralEffectiveValue = self.priceOracle.price(token: withdrawType) * trueCredit * self.collateralFactor[withdrawType]!

                // Check what the new health would be if we took out all of this collateral
                let potentialHealth = AlpenFlow.healthComputation(effectiveCollateral: effectiveCollateralAfterDeposit - collateralEffectiveValue,
                        effectiveDebt: effectiveDebtAfterDeposit)

                // Does drawing down all of the collateral go below the target health? Then the max withdrawal comes from collateral only.
                if potentialHealth <= targetHealth {
                    // We can will hit the health target before using up all of the withdraw token credit. We can easily
                    // compute how many units of the token would be bring the position down to the target health.

                    let availableHeath = targetHealth - healthAfterDeposit
                    let availableEffectiveValue = availableHeath * effectiveDebtAfterDeposit

                    // The amount of the token we can take using that amount of heath
                    let availableTokenCount = availableEffectiveValue * self.collateralFactor[withdrawType]! / self.priceOracle.price(token: withdrawType)

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

            // At this point, we're either dealing with a position that either didn't have a credit balance in the withdraw
            // token, or we've accounted for the credit balance and adjusted the effective collateral above.

            // We have two cases to deal with: The normal case (handled second, and the case where
            // the position's health (after any deposit made above) is at maximum (i.e the debt
            // is at or near zero).
            var availableDebtIncrease = (effectiveCollateralAfterDeposit / targetHealth) - effectiveDebtAfterDeposit

            let availableTokens = availableDebtIncrease * self.borrowFactor[withdrawType]! / self.priceOracle.price(token: withdrawType)

            return availableTokens + collateralTokenCount
        }

        // Returns the health the position would have if the given amount of the specified token were deposited.
        access(all) fun healthAfterDeposit(pid: UInt64, type: Type, amount: UFix64): UFix64 {
            let balanceSheet = self.positionBalanceSheet(pid: pid)

            let position = &self.positions[pid] as auth(EImplementation) &InternalPosition?!
            let tokenState = self.tokenState(type: type)
            let priceOracle = &self.priceOracle as &{PriceOracle}

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
                let trueDebt = AlpenFlow.scaledBalanceToTrueBalance(scaledBalance: debtBalance,
                    interestIndex: tokenState.debitInterestIndex)

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

            return AlpenFlow.healthComputation(effectiveCollateral: balanceSheet.effectiveCollateral + effectiveCollateralIncrease,
                    effectiveDebt: balanceSheet.effectiveDebt - effectiveDebtDecrease)
        }

        // Returns health value of this position if the given amount of the specified token were withdrawn without
        // using the top up source.
        // NOTE: This method can return health values below 1.0, which aren't actually allowed. This indicates
        // that the proposed withdrawal would fail (unless a top up source is available and used).
        access(all) fun healthAfterWithdrawal(pid: UInt64, type: Type, amount: UFix64): UFix64 {
            let balanceSheet = self.positionBalanceSheet(pid: pid)

            let position = &self.positions[pid] as auth(EImplementation) &InternalPosition?!
            let tokenState = self.tokenState(type: type)
            let priceOracle = &self.priceOracle as &{PriceOracle}

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
                let trueCredit = AlpenFlow.scaledBalanceToTrueBalance(scaledBalance: creditBalance,
                    interestIndex: tokenState.creditInterestIndex)

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

            return AlpenFlow.healthComputation(effectiveCollateral: balanceSheet.effectiveCollateral - effectiveCollateralDecrease,
                    effectiveDebt: balanceSheet.effectiveDebt + effectiveDebtIncrease)
        }

        // Rebalances the position to the target health value. If force is true, the position will be
        // rebalanced even if it is currently healthy, otherwise, this function will do nothing if the
        // position is within the min/max health bounds.
        access(EPosition) fun rebalancePosition(pid: UInt64, force: Bool) {
            let position = &self.positions[pid] as auth(EImplementation) &InternalPosition?!
            let balanceSheet = self.positionBalanceSheet(pid: pid)

            if !force && (balanceSheet.health >= position.minHealth && balanceSheet.health <= position.maxHealth) {
                // We aren't forcing the update, and the position is already between it's desired min and max. Nothing to do!
                return
            }

            if balanceSheet.health < position.targetHealth {
                // The position is undercollateralized, see if the source can get more collateral to bring it up to the target health.
                if position.topUpSource != nil {
                    let topUpSource = position.topUpSource!
                    let idealDeposit = self.fundsRequiredForTargetHealth(pid: pid, type: topUpSource.sourceType(), targetHealth: position.targetHealth)

                    let pulledVault <- topUpSource.withdrawAvailable(maxAmount: idealDeposit)
                    self.depositAndPush(pid: pid, from: <-pulledVault, pushToDrawDownSink: false)
                }
            } else if balanceSheet.health > position.targetHealth {
                // The position is overcollateralized, we'll withdraw funds to match the target health and offer it to the sink.
                if position.drawDownSink != nil {
                    let drawDownSink = position.drawDownSink!
                    let sinkType = drawDownSink.sinkType()
                    let idealWithdrawal = self.fundsAvailableAboveTargetHealth(pid: pid, type: sinkType, targetHealth: position.targetHealth)

                    // Compute how many tokens of the sink's type are available to hit our target health.
                    let sinkCapacity = drawDownSink.availableCapacity()
                    let sinkAmount = (idealWithdrawal > sinkCapacity) ? sinkCapacity : idealWithdrawal
                    let sinkVault <- self.withdrawAndPull(pid: pid, type: sinkType, amount: sinkAmount, pullFromTopUpSource: false)

                    // Push what we can into the sink, and redeposit the rest
                    position.drawDownSink!.depositAvailable(from: &sinkVault as auth(Withdraw) &{Vault})
                    self.depositAndPush(pid: pid, from: <-sinkVault, pushToDrawDownSink: false)
                }
            }
        }

        access(EImplementation) fun asyncUpdate() {
            // TODO: In the production version, this function should only process some positions (limited by positionsPerUpdate) AND
            // it should schedule each udpate to run in its own callback, so a revert() call from one update (for example, if a source or
            // sink aborts) won't prevent other positions from being updated.
            while self.positionsNeedingUpdates.length > 0 {
                let pid = self.positionsNeedingUpdates.removeFirst()
                self.asyncUpdatePosition(pid: pid)
                self.queuePositionForUpdateIfNecessary(pid: pid)
            }
        }

        access(EImplementation) fun asyncUpdatePosition(pid: UInt64) {
            let position = &self.positions[pid] as auth(EImplementation) &InternalPosition?!

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

    access(all) struct PositionSink: Sink {
        access(self) let pool: Capability<auth(EPosition) &Pool>
        access(self) let id: UInt64
        access(self) let type: Type
        access(self) let pushToDrawDownSink: Bool

        access(all) view fun sinkType(): Type {
            return self.type
        }

        access(all) fun availableCapacity(): UFix64 {
            // A position object has no limit to deposits
            return UFix64.max
        }
        
        access(all) fun depositAvailable(from: auth(Withdraw) &{Vault}) {
            let pool = self.pool.borrow()!
            pool.depositAndPush(pid: self.id, from: <-from.withdraw(amount: from.balance), pushToDrawDownSink: self.pushToDrawDownSink)
        }
       

        init(id: UInt64, pool: Capability<auth(EPosition) &Pool>, type: Type, pushToDrawDownSink: Bool) {
            self.id = id
            self.pool = pool
            self.type = type
            self.pushToDrawDownSink = pushToDrawDownSink
        }
    }

    access(all) struct PositionSource: Source { 
        access(all) let pool: Capability<auth(EPosition) &Pool>
        access(all) let id: UInt64
        access(all) let type: Type
        access(all) let pullFromTopUpSource: Bool

        access(all) view fun sourceType(): Type {
            return self.type
        }

        access(all) fun availableBalance(): UFix64 {
            let pool: auth(AlpenFlow.EPosition) &AlpenFlow.Pool = self.pool.borrow()!
            return pool.availableBalance(pid: self.id, type: self.type, pullFromTopUpSource: self.pullFromTopUpSource)
        }

        access(all) fun withdrawAvailable(maxAmount: UFix64): @{Vault} {
            let pool = self.pool.borrow()!
            let available = pool.availableBalance(pid: self.id, type: self.type, pullFromTopUpSource: self.pullFromTopUpSource)
            let withdrawAmount = (available > maxAmount) ? maxAmount : available
            return <- pool.withdrawAndPull(pid: self.id, type: self.type, amount: withdrawAmount, pullFromTopUpSource: self.pullFromTopUpSource)
        }

        init(id: UInt64, pool: Capability<auth(EPosition) &Pool>, type: Type, pullFromTopUpSource: Bool) {
            self.id = id
            self.pool = pool
            self.type = type
            self.pullFromTopUpSource = pullFromTopUpSource
        }
    }

    access(all) struct Position {
        access(self) let id: UInt64
        access(self) let pool: Capability<auth(EPosition) &Pool>

        // Returns the balances (both positive and negative) for all tokens in this position.
        access(all) fun getBalances(): [PositionBalance] {
            return []
        }

        // Returns the maximum amount of the given token type that could be withdrawn from this position.
        access(all) fun availableBalance(type: Type, pullFromTopUpSource: Bool): UFix64 {
            let pool: auth(AlpenFlow.EPosition) &AlpenFlow.Pool = self.pool.borrow()!
            return pool.availableBalance(pid: self.id, type: type, pullFromTopUpSource: pullFromTopUpSource)
        }

        access(all) fun getHealth(): UFix64 {
            let pool: auth(AlpenFlow.EPosition) &AlpenFlow.Pool = self.pool.borrow()!
            return pool.positionHealth(pid: self.id)
        }

        access(all) fun getTargetHealth(): UFix64 {
            return 0.0
        }

        access(all) fun setTargetHealth(targetHealth: UFix64) {
        }

        access(all) fun getMinHealth(): UFix64 {
            return 0.0
        }

        access(all) fun setMinHealth(minHealth: UFix64) {
        }

        access(all) fun getMaxHealth(): UFix64 {
            return 0.0
        }

        access(all) fun setMaxHealth(maxHealth: UFix64) {
        }

        // A simple deposit function that doesn't immedialy push to the draw-down sink.
        access(all) fun deposit(pid: UInt64, from: @{Vault}) {
            let pool = self.pool.borrow()!
            pool.depositAndPush(pid: self.id, from: <-from, pushToDrawDownSink: false)
        }

        // Deposits tokens into the position, paying down debt (if one exists) and/or
        // increasing collateral. The provided Vault must be a supported token type.
        //
        // If pushToDrawDownSink is true, the position will immediately force a rebalance
        // after the deposit, which will push funds into the draw-down sink to bring the
        // position back to the target health. (If pushToDrawDownSink is false, the position
        // may still rebalance itself automatically if it's outside the configured health bounds.)
        access(all) fun depositAndPush(from: @{Vault}, pushToDrawDownSink: Bool)
        {
            let pool = self.pool.borrow()!
            pool.depositAndPush(pid: self.id, from: <-from, pushToDrawDownSink: pushToDrawDownSink)
        }

        // A simple withdraw function that won't use the top-up source.
        access(all) fun withdraw(type: Type, amount: UFix64): @{Vault} {
            return <- self.withdrawAndPull(type: type, amount: amount, pullFromTopUpSource: false)
        }

        // Withdraws tokens from the position by withdrawing collateral and/or
        // creating/increasing a loan. The requested Vault type must be a supported token.
        //
        // If pullFromTopUpSource is false, this method will only allow you to withdraw
        // funds that are currently available in the position. If pullFromTopUpSource is true, the
        // position will also attempt to withdraw funds from the top-up Source to
        // meet as much of the request as possible.
        access(all) fun withdrawAndPull(type: Type, amount: UFix64, pullFromTopUpSource: Bool): @{Vault}
        {
            let pool = self.pool.borrow()!
            return <- pool.withdrawAndPull(pid: self.id, type: type, amount: amount, pullFromTopUpSource: pullFromTopUpSource)
        }

        // Returns a NEW sink for the given token type that will accept deposits of that token and
        // update the position's collateral and/or debt accordingly. Note that calling this method multiple
        // times will create multiple sinks, each of which will continue to work regardless of how many
        // other sinks have been created.
        access(all) fun createSink(type: Type, pushToDrawDownSink: Bool): {Sink} {
            return PositionSink(id: self.id, pool: self.pool, type: type, pushToDrawDownSink: pushToDrawDownSink)
        }

        // Returns a NEW source for the given token type that will provide withdrawals of that token and
        // update the position's collateral and/or debt accordingly. Note that calling this method multiple
        // times will create multiple sources, each of which will continue to work regardless of how many
        // other sources have been created.
        //
        // This source will pass its pullFromTopUpSource value to the withdraw function. Use
        // pullFromTopUpSource == true with care!
        access(all) fun createSource(type: Type, pullFromTopUpSource: Bool): {Source} {
            return PositionSource(id: self.id, pool: self.pool, type: type, pullFromTopUpSource: pullFromTopUpSource)
        }

        // Provides a sink to the Position that will have tokens proactively pushed into it when the
        // position has excess collateral. (Remember that sinks do NOT have to accept all tokens provided
        // to them; the sink can choose to accept only some (or none) of the tokens provided, leaving the position
        // overcollateralized.)
        //
        // Each position can have only one sink, and the sink must accept the default token type
        // configured for the pool. Providing a new sink will replace the existing sink. Pass nil
        // to configure the position to not push tokens.
        access(all) fun provideDrawDownSink(sink: {Sink}?) {
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
        access(all) fun provideTopUpSource(source: {Source}?) {
            let pool = self.pool.borrow()!
            pool.provideTopUpSource(pid: self.id, source: source)
        }

        init(id: UInt64, pool: Capability<auth(EPosition) & Pool>) {
            self.id = id
            self.pool = pool
        }
    }

    access(all) resource MoetVault: Vault {
        access(all) var balance: UFix64

        access(all) fun deposit(from: @{Vault}) {
            destroy from
        }

        access(Withdraw) fun withdraw(amount: UFix64): @{Vault} {
            return <- create FlowVault()
        }

        init(balance: UFix64) {
            self.balance = balance
        }
   }

   access(all) resource MoetManager {
        access(all) fun mint(amount: UFix64): @MoetVault {
            return <- create MoetVault(balance: amount)
        }

        access(all) fun burn(vault: @{Vault}) {
            destroy vault
        }
   }
}