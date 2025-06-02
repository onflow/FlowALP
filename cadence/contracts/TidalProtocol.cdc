import "FungibleToken"
import "ViewResolver"
import "MetadataViews"
import "FungibleTokenMetadataViews"
import "DFB"
// CHANGE: Import FlowToken to use the real FLOW token implementation
// This replaces our test FlowVault with the actual Flow token
import "FlowToken"
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

    // RESTORED: Oracle and DeFi interfaces from Dieter's implementation
    // These are critical for dynamic price-based position management
    
    access(all) struct interface PriceOracle {
        access(all) view fun unitOfAccount(): Type
        access(all) fun price(token: Type): UFix64
    }

    access(all) struct interface Flasher {
        access(all) view fun borrowType(): Type
        access(all) fun flashLoan(amount: UFix64, sink: {DFB.Sink}, source: {DFB.Source}): UFix64
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
        access(all) fun swap(inVault: @{FungibleToken.Vault}, quote:{SwapQuote}?): @{FungibleToken.Vault}
        access(all) fun swapBack(residual: @{FungibleToken.Vault}, quote:{SwapQuote}): @{FungibleToken.Vault}
    }

    // RESTORED: SwapSink implementation for automated rebalancing
    access(all) struct SwapSink: DFB.Sink {
        access(contract) let uniqueID: {DFB.UniqueIdentifier}?
        access(self) let swapper: {Swapper}
        access(self) let sink: {DFB.Sink}

        init(swapper: {Swapper}, sink: {DFB.Sink}) {
            pre {
                swapper.outType() == sink.getSinkType()
            }

            self.uniqueID = nil
            self.swapper = swapper
            self.sink = sink
        }

        access(all) view fun getSinkType(): Type {
            return self.swapper.inType()
        }

        access(all) fun minimumCapacity(): UFix64 {
            let sinkCapacity = self.sink.minimumCapacity()
            return self.swapper.quoteIn(outAmount: sinkCapacity).amountIn
        }

        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            let limit = self.sink.minimumCapacity()

            let swapQuote = self.swapper.quoteIn(outAmount: limit)
            let sinkLimit = swapQuote.amountIn
            let swapVault <- from.withdraw(amount: 0.0)

            if sinkLimit < from.balance {
                // The sink is limited to fewer tokens that we have available. Only swap
                // the amount we need to meet the sink limit.
                swapVault.deposit(from: <-from.withdraw(amount: sinkLimit))
            }
            else {
                // The sink can accept all of the available tokens, so we swap everything
                swapVault.deposit(from: <-from.withdraw(amount: from.balance))
            }

            let swappedTokens <- self.swapper.swap(inVault: <-swapVault, quote: swapQuote)
            self.sink.depositCapacity(from: &swappedTokens as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})

            if swappedTokens.balance > 0.0 {
                from.deposit(from: <-self.swapper.swapBack(residual: <-swappedTokens, quote: swapQuote))
            } else {
                destroy swappedTokens
            }
        }
    }

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

        init(interestCurve: {InterestCurve}) {
            self.lastUpdate = 0.0
            self.totalCreditBalance = 0.0
            self.totalDebitBalance = 0.0
            self.creditInterestIndex = 10000000000000000
            self.debitInterestIndex = 10000000000000000
            self.currentCreditRate = 10000000000000000
            self.currentDebitRate = 10000000000000000
            self.interestCurve = interestCurve
            
            // RESTORED: Default deposit rate limiting values from Dieter's implementation
            // Default: 1000 tokens per second deposit rate, 1M token capacity cap
            self.depositRate = 1000.0
            self.depositCapacity = 1000000.0
            self.depositCapacityCap = 1000000.0
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
        access(self) var priceOracle: {PriceOracle}

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

        init(defaultToken: Type, priceOracle: {PriceOracle}) {
            pre {
                priceOracle.unitOfAccount() == defaultToken: "Price oracle must return prices in terms of the default token"
            }

            self.version = 0
            self.globalLedger = {defaultToken: TokenState(interestCurve: SimpleInterestCurve())}
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
            let position = &self.positions[pid]! as auth(EImplementation) &InternalPosition
            let tokenState = &self.globalLedger[type]! as auth(EImplementation) &TokenState

            // If this position doesn't currently have an entry for this token, create one.
            if position.balances[type] == nil {
                position.balances[type] = InternalBalance()
            }

            // Update the global interest indices on the affected token to reflect the passage of time.
            tokenState.updateInterestIndices()

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

        access(EPosition) fun withdraw(pid: UInt64, amount: UFix64, type: Type): @{FungibleToken.Vault} {
            pre {
                self.positions[pid] != nil: "Invalid position ID"
                self.globalLedger[type] != nil: "Invalid token type"
                amount > 0.0: "Withdrawal amount must be positive"
            }

            // Get a reference to the user's position and global token state for the affected token.
            let position = &self.positions[pid]! as auth(EImplementation) &InternalPosition
            let tokenState = &self.globalLedger[type]! as auth(EImplementation) &TokenState

            // If this position doesn't currently have an entry for this token, create one.
            if position.balances[type] == nil {
                position.balances[type] = InternalBalance()
            }

            // Update the global interest indices on the affected token to reflect the passage of time.
            tokenState.updateInterestIndices()

            let reserveVault = (&self.reserves[type] as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?)!

            // Reflect the withdrawal in the position's balance
            position.balances[type]!.recordWithdrawal(amount: amount, tokenState: tokenState)

            // Ensure that this withdrawal doesn't cause the position to be overdrawn.
            assert(self.positionHealth(pid: pid) >= 1.0, message: "Position is overdrawn")

            // Update the internal interest rate to reflect the new credit balance
            tokenState.updateInterestRates()

            return <- reserveVault.withdraw(amount: amount)
        }

        // Returns the health of the given position, which is the ratio of the position's effective collateral
        // to its debt (as denominated in the default token). ("Effective collateral" means the
        // value of each credit balance times the liquidation threshold for that token. i.e. the maximum borrowable amount)
        access(all) fun positionHealth(pid: UInt64): UFix64 {
            let position = &self.positions[pid]! as auth(EImplementation) &InternalPosition

            // Get the position's collateral and debt values in terms of the default token.
            var effectiveCollateral = 0.0
            var effectiveDebt = 0.0

            for type in position.balances.keys {
                let balance = position.balances[type]!
                let tokenState = &self.globalLedger[type]! as auth(EImplementation) &TokenState
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
            let position = &self.positions[pid]! as auth(EImplementation) &InternalPosition
            let priceOracle = &self.priceOracle as &{PriceOracle}

            // Get the position's collateral and debt values in terms of the default token.
            var effectiveCollateral = 0.0
            var effectiveDebt = 0.0

            for type in position.balances.keys {
                let balance = position.balances[type]!
                let tokenState = &self.globalLedger[type]! as auth(EImplementation) &TokenState
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
            let position = &self.positions[pid]! as auth(EImplementation) &InternalPosition
            let balances: [PositionBalance] = []
            
            for type in position.balances.keys {
                let balance = position.balances[type]!
                let tokenState = &self.globalLedger[type]! as auth(EImplementation) &TokenState
                
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
            let position = &self.positions[pid]! as auth(EImplementation) &InternalPosition

            var effectiveCollateralAfterWithdrawal = balanceSheet.effectiveCollateral
            var effectiveDebtAfterWithdrawal = balanceSheet.effectiveDebt

            if withdrawAmount != 0.0 {
                if position.balances[withdrawType] == nil || position.balances[withdrawType]!.direction == BalanceDirection.Debit {
                    // If the position doesn't have any collateral for the withdrawn token, we can just compute how much
                    // additional effective debt the withdrawal will create.
                    effectiveDebtAfterWithdrawal = balanceSheet.effectiveDebt + 
                        (withdrawAmount * self.priceOracle.price(token: withdrawType) / self.borrowFactor[withdrawType]!)
                } else {
                    let withdrawTokenState = &self.globalLedger[withdrawType]! as auth(EImplementation) &TokenState
                    withdrawTokenState.updateForTimeChange()

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
                let depositTokenState = &self.globalLedger[depositType]! as auth(EImplementation) &TokenState
                depositTokenState.updateForTimeChange()
                
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
            let position = &self.positions[pid]! as auth(EImplementation) &InternalPosition

            var effectiveCollateralAfterDeposit = balanceSheet.effectiveCollateral
            var effectiveDebtAfterDeposit = balanceSheet.effectiveDebt

            if depositAmount != 0.0 {
                if position.balances[depositType] == nil || position.balances[depositType]!.direction == BalanceDirection.Credit {
                    // If there's no debt for the deposit token, we can just compute how much additional effective collateral the deposit will create.
                    effectiveCollateralAfterDeposit = balanceSheet.effectiveCollateral + 
                        (depositAmount * self.priceOracle.price(token: depositType) * self.collateralFactor[depositType]!)
                } else {
                    let depositTokenState = &self.globalLedger[depositType]! as auth(EImplementation) &TokenState
                    depositTokenState.updateForTimeChange()

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
                let withdrawTokenState = &self.globalLedger[withdrawType]! as auth(EImplementation) &TokenState
                withdrawTokenState.updateForTimeChange()
                
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
            let position = &self.positions[pid]! as auth(EImplementation) &InternalPosition
            let tokenState = &self.globalLedger[type]! as auth(EImplementation) &TokenState
            tokenState.updateForTimeChange()

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
            let position = &self.positions[pid]! as auth(EImplementation) &InternalPosition
            let tokenState = &self.globalLedger[type]! as auth(EImplementation) &TokenState
            tokenState.updateForTimeChange()

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
    }

    access(all) struct Position {
        access(self) let id: UInt64
        access(self) let pool: Capability<auth(EPosition) &Pool>

        // Returns the balances (both positive and negative) for all tokens in this position.
        access(all) fun getBalances(): [PositionBalance] {
            return []
        }

        // Returns the maximum amount of the given token type that could be withdrawn from this position.
        access(all) fun getAvailableBalance(type: Type): UFix64 {
            return 0.0
        }

        // Returns the maximum amount of the given token type that could be deposited into this position.
        access(all) fun getDepositCapacity(type: Type): UFix64 {
            return 0.0
        }
        // Deposits tokens into the position, paying down debt (if one exists) and/or
        // increasing collateral. The provided Vault must be a supported token type.
        access(all) fun deposit(from: @{FungibleToken.Vault})
        {
            destroy from
        }

        // Withdraws tokens from the position by withdrawing collateral and/or
        // creating/increasing a loan. The requested Vault type must be a supported token.
        access(all) fun withdraw(type: Type, amount: UFix64): @{FungibleToken.Vault}
        {
            // CHANGE: This is a stub implementation - real implementation would call pool.withdraw
            panic("Position.withdraw is not implemented - use Pool.withdraw directly")
        }

        // Returns a NEW sink for the given token type that will accept deposits of that token and
        // update the position's collateral and/or debt accordingly. Note that calling this method multiple
        // times will create multiple sinks, each of which will continue to work regardless of how many
        // other sinks have been created.
        access(all) fun createSink(type: Type): {DFB.Sink} {
            let pool = self.pool.borrow()!
            return TidalProtocolSink(pool: pool, positionID: self.id)
        }

        // Returns a NEW source for the given token type that will service withdrawals of that token and
        // update the position's collateral and/or debt accordingly. Note that calling this method multiple
        // times will create multiple sources, each of which will continue to work regardless of how many
        // other sources have been created.
        access(all) fun createSource(type: Type): {DFB.Source} {
            let pool = self.pool.borrow()!
            return TidalProtocolSource(pool: pool, positionID: self.id, tokenType: type)
        }

        // Provides a sink to the Position that will have tokens proactively pushed into it when the
        // position has excess collateral. (Remember that sinks do NOT have to accept all tokens provided
        // to them; the sink can choose to accept only some (or none) of the tokens provided, leaving the position
        // overcollateralized.)
        //
        // Each position can have only one sink, and the sink must accept the default token type
        // configured for the pool. Providing a new sink will replace the existing sink. Pass nil
        // to configure the position to not push tokens.
        access(all) fun provideSink(sink: {DFB.Sink}?) {
        }

        // Provides a source to the Position that will have tokens proactively pulled from it when the
        // position has insufficient collateral. If the source can cover the position's debt, the position
        // will not be liquidated.
        //
        // Each position can have only one source, and the source must accept the default token type
        // configured for the pool. Providing a new source will replace the existing source. Pass nil
        // to configure the position to not pull tokens.
        access(all) fun provideSource(source: {DFB.Source}?) {
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
    access(all) fun createPool(defaultToken: Type, priceOracle: {PriceOracle}): @Pool {
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