import "FungibleToken"
import "ViewResolver"
import "Burner"
import "MetadataViews"
import "FungibleTokenMetadataViews"
import "DFB"
import "MOET"

/*
    MISSING FUNCTIONALITY:
    - Pulling MOET from a position with available balance as the user - needed if a Sink is not required by the protocol
        -> implies a new protocol-defined Source, logic ingrained in existing Source, or route on the Position enabling this withdrawal
    - Pushing MOET to a position as the protocol on deposits - needed for AutoBalancer recollateralization cycle
        -> integrate into Pool.deposit so that MOET can be routed to downstream connectors
    - Balance tracking for MOET that has been withdrawn against a position's collateral balance
    - Active lending protocol functionality on per-position basis

    ??? How does:
    - The pool determine the MOET balance available to push?
    - Maintain and update the issued loan balance?
 */
access(all) contract TidalProtocol {

    /// The canonical StoragePath where the primary TidalProtocol Pool is stored
    access(all) let PoolStoragePath: StoragePath
    /// The canonical PublicPath where the primary TidalProtocol Pool can be accessed publicly
    access(all) let PoolPublicPath: PublicPath

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
        repaymentSource: {DFB.Source}?
    ): Position {
        let pid = self.borrowPool().createPosition(funds: <-collateral, issuanceSink: issuanceSink, repaymentSource: repaymentSource)
        let cap = self.account.capabilities.storage.issue<auth(EPosition) &Pool>(self.PoolStoragePath)
        return Position(id: pid, pool: cap)
    }

    /* --- TEST METHODS | REMOVE BEFORE PRODUCTION & REFACTOR TESTS --- */

    // CHANGE: Add a proper pool creation function for tests
    access(all) fun createPool(defaultToken: Type, defaultTokenThreshold: UFix64): @Pool {
        return <- create Pool(defaultToken: defaultToken, defaultTokenThreshold: defaultTokenThreshold)
    }

    /* --- CONSTRUCTS & INTERNAL METHODS ---- */

    access(all) entitlement EPosition
    access(all) entitlement EGovernance
    access(all) entitlement EImplementation

    // A structure used internally to track a position's balance for a particular token.
    access(all) struct InternalBalance {
        access(all) var direction: BalanceDirection

        // Internally, position balances are tracked using a "scaled balance". The "scaled balance" is the
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

    access(all) struct InternalPosition {
        access(mapping ImplementationUpdates) var balances: {Type: InternalBalance}
        access(mapping ImplementationUpdates) var issuanceSinks: {Type: {DFB.Sink}}
        access(mapping ImplementationUpdates) var repaymentSources: {Type: {DFB.Source}}

        init() {
            self.balances = {}
            self.issuanceSinks = {}
            self.repaymentSources = {}
        }
    }

    access(all) struct interface InterestCurve {
        access(all) fun interestRate(creditBalance: UFix64, debitBalance: UFix64): UFix64 {
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

        access(all) fun updateInterestIndices() {
            let currentTime = getCurrentBlock().timestamp
            let timeDelta = currentTime - self.lastUpdate
            self.creditInterestIndex = TidalProtocol.compoundInterestIndex(oldIndex: self.creditInterestIndex, perSecondRate: self.currentCreditRate, elapsedSeconds: timeDelta)
            self.debitInterestIndex = TidalProtocol.compoundInterestIndex(oldIndex: self.debitInterestIndex, perSecondRate: self.currentDebitRate, elapsedSeconds: timeDelta)
            self.lastUpdate = currentTime
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
        access(self) var positions: {UInt64: InternalPosition}

        // The actual reserves of each token
        access(self) var reserves: @{Type: {FungibleToken.Vault}}

        // Auto-incrementing position identifier counter
        access(self) var nextPositionID: UInt64

        // The default token type used as the "unit of account" for the pool.
        access(self) let defaultToken: Type

        // The exchange rate between the default token and each other token supported by the pool.
        // Multiplying a quantity of the specified token by the amount stored in this dictionary
        // will provide the value of that quantity of tokens in terms of the default token.
        access(self) var exchangeRates: {Type: UFix64}

        // The liquidation threshold for each token.
        access(self) var liquidationThresholds: {Type: UFix64}

        init(defaultToken: Type, defaultTokenThreshold: UFix64) {
            self.version = 0
            self.globalLedger = {defaultToken: TokenState(interestCurve: SimpleInterestCurve())}
            self.positions = {}
            self.reserves <- {}
            self.defaultToken = defaultToken
            self.exchangeRates = {defaultToken: 1.0}
            self.liquidationThresholds = {defaultToken: defaultTokenThreshold}
            self.nextPositionID = 0

            // CHANGE: Don't create vault here - let the caller provide initial reserves
            // The pool starts with empty reserves map
            // Vaults will be added when tokens are first deposited
        }

        /// ??? - how does a caller get out their loaned funds if we don't require a Sink for the protocol to push to and we aren't returning a Vault?
        access(EPosition) fun deposit(pid: UInt64, funds: @{FungibleToken.Vault}) {
            pre {
                self.positions[pid] != nil: "Invalid position ID \(pid)"
                self.globalLedger[funds.getType()] != nil: "Invalid token type \(funds.getType().identifier)"
                funds.balance > 0.0: "Deposit amount must be positive" // TODO: Consider no-op here instead
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

            // TODO: Push the corresponding MOET amount to the InternalPosition Sink if one exists
            if let issuanceSink = position.issuanceSinks[type] {
                // assess how much can be issued based on the updated collateral balance
                // adjust balance to reflect the loaned amount about to be pushed out of the protocol
                // mint MOET
                // deposit to sink
            }
        }

        access(EPosition) fun withdraw(pid: UInt64, amount: UFix64, type: Type): @{FungibleToken.Vault} {
            pre {
                self.positions[pid] != nil: "Invalid position ID"
                self.globalLedger[type] != nil: "Invalid token type"
                amount > 0.0: "Withdrawal amount must be positive" // TODO: consider empty vault early return
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
            var totalDebt = 0.0

            for type in position.balances.keys {
                let balance = position.balances[type]!
                let tokenState = &self.globalLedger[type]! as auth(EImplementation) &TokenState
                if balance.direction == BalanceDirection.Credit {
                    let trueBalance = TidalProtocol.scaledBalanceToTrueBalance(scaledBalance: balance.scaledBalance,
                        interestIndex: tokenState.creditInterestIndex)

                    effectiveCollateral = effectiveCollateral + trueBalance * self.liquidationThresholds[type]!
                } else {
                    let trueBalance = TidalProtocol.scaledBalanceToTrueBalance(scaledBalance: balance.scaledBalance,
                        interestIndex: tokenState.debitInterestIndex)

                    totalDebt = totalDebt + trueBalance
                }
            }

            // Calculate the health as the ratio of collateral to debt.
            if totalDebt == 0.0 {
                return 1.0
            }
            return effectiveCollateral / totalDebt
        }

        /// Creates a lending position against the provided collateral funds, depositing the loaned amount to the
        /// given Sink. If a Source is provided, the position will be configured to pull loan repayment when the loan
        /// becomes undercollateralized, preferring repayment to outright liquidation.
        access(all) fun createPosition(
            funds: @{FungibleToken.Vault},
            issuanceSink: {DFB.Sink},
            repaymentSource: {DFB.Source}?
        ): UInt64 {
            pre {
                self.globalLedger[funds.getType()] != nil: "Invalid token type \(funds.getType().identifier)"
            }
            // construct a new InternalPosition, assigning it the current position ID
            let id = self.nextPositionID
            self.nextPositionID = self.nextPositionID + 1
            self.positions[id] = InternalPosition()

            // assign issuance & repayment connectors within the InternalPosition
            let iPos = &self.positions[id]! as auth(EImplementation) &InternalPosition
            iPos.issuanceSinks[funds.getType()] = issuanceSink
            if repaymentSource != nil {
                iPos.repaymentSources[funds.getType()] = repaymentSource
            }

            // deposit the initial funds & return the position ID
            self.deposit(pid: id, funds: <-funds)
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

        /// Sets the Sink within the InternalPosition to which funds are deposited when a position is determined to be
        /// overcollaterized. If `nil`, no overcollateralized value is not automatically pushed
        access(contract) fun providePositionSink(pid: UInt64, type: Type, sink: {DFB.Sink}?) {
            let iPos = &self.positions[pid]! as auth(EImplementation) &InternalPosition
            iPos.issuanceSinks[type] = sink
        }

        /// Sets the Source within the InternalPosition from which funds are withdrawn when a position is determined to
        /// be undercollaterized. If `nil`, no funds are automatically pulled, though note that such cases risk
        /// automated liquidation
        access(contract) fun providePositionSource(pid: UInt64, type: Type, source: {DFB.Source}?) {
            let iPos = &self.positions[pid]! as auth(EImplementation) &InternalPosition
            iPos.repaymentSources[type] = source
        }
    }

    // TODO: Consider making this a resource given how critical it is to accessing a loan
    access(all) struct Position {
        access(self) let id: UInt64
        access(self) let pool: Capability<auth(EPosition) &Pool>

        init(id: UInt64, pool: Capability<auth(EPosition) &Pool>) {
            pre {
                pool.check(): "Invalid Pool Capability provided - cannot construct Position"
            }
            self.id = id
            self.pool = pool
        }

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
        access(all) fun deposit(from: @{FungibleToken.Vault}) {
            pre {
                self.pool.check(): "This Position's Pool capability is no longer valid - cannot deposit"
            }
            self.pool.borrow()!.deposit(pid: self.id, funds: <-from)
        }

        // Withdraws tokens from the position by withdrawing collateral and/or
        // creating/increasing a loan. The requested Vault type must be a supported token.
        access(all) fun withdraw(type: Type, amount: UFix64): @{FungibleToken.Vault} {
            pre {
                self.pool.check(): "This Position's Pool capability is no longer valid - cannot withdraw"
            }
            return <- self.pool.borrow()!.withdraw(pid: self.id, amount: amount, type: type)
        }

        // Returns a NEW sink for the given token type that will accept deposits of that token and
        // update the position's collateral and/or debt accordingly. Note that calling this method multiple
        // times will create multiple sinks, each of which will continue to work regardless of how many
        // other sinks have been created.
        access(all) fun createSink(type: Type): {DFB.Sink} {
            pre {
                self.pool.check(): "This Position's Pool capability is no longer valid - cannot create Sink"
            }
            return TidalProtocolSink(pool: self.pool, positionID: self.id, tokenType: type)
        }

        // Returns a NEW source for the given token type that will service withdrawals of that token and
        // update the position's collateral and/or debt accordingly. Note that calling this method multiple
        // times will create multiple sources, each of which will continue to work regardless of how many
        // other sources have been created.
        access(all) fun createSource(type: Type): {DFB.Source} {
            pre {
                self.pool.check(): "This Position's Pool capability is no longer valid - cannot create Sink"
            }
            return TidalProtocolSource(pool: self.pool, positionID: self.id, tokenType: type)
        }

        // Provides a sink to the Position that will have tokens proactively pushed into it when the
        // position has excess collateral. (Remember that sinks do NOT have to accept all tokens provided
        // to them; the sink can choose to accept only some (or none) of the tokens provided, leaving the position
        // overcollateralized.)
        //
        // Each position can have only one sink, and the sink must accept the default token type
        // configured for the pool. Providing a new sink will replace the existing sink. Pass nil
        // to configure the position to not push tokens.
        access(all) fun provideSink(forType: Type, sink: {DFB.Sink}?) {
            pre {
                self.pool.check(): "This Position's Pool capability is no longer valid - cannot withdraw"
            }
            self.pool.borrow()!.providePositionSink(pid: self.id, type: forType, sink: sink)
        }

        // Provides a source to the Position that will have tokens proactively pulled from it when the
        // position has insufficient collateral. If the source can cover the position's debt, the position
        // will not be liquidated.
        //
        // Each position can have only one source, and the source must accept the default token type
        // configured for the pool. Providing a new source will replace the existing source. Pass nil
        // to configure the position to not pull tokens.
        access(all) fun provideSource(forType: Type, source: {DFB.Source}?) {
            self.pool.borrow()!.providePositionSource(pid: self.id, type: forType, source: source)
        }
    }

    // DFB.Sink implementation for TidalProtocol
    access(all) struct TidalProtocolSink: DFB.Sink {
        access(contract) let uniqueID: {DFB.UniqueIdentifier}? // TODO: Consider how this field will be set
        access(contract) let pool: Capability<auth(EPosition) &Pool>
        access(contract) let positionID: UInt64
        access(contract) let tokenType: Type

        init(pool: Capability<auth(EPosition) &Pool>, positionID: UInt64, tokenType: Type) {
            pre {
                pool.check(): "Invalid Pool Capability provided - cannot construct TidalProtocolSink"
            }
            self.uniqueID = nil
            self.pool = pool
            self.positionID = positionID
            self.tokenType = tokenType
        }

        access(all) view fun getSinkType(): Type {
            return self.tokenType
        }

        access(all) fun minimumCapacity(): UFix64 {
            // For now, return max as there's no limit
            // TODO: Consider sentinel value returned by DFB.Sink.minimumCapacity - perhaps make optional & `nil` == no_limit
            return UFix64.max
        }

        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            pre {
                self.pool.check(): "Internal Pool Capability is invalid - cannot depositCapacity"
            }
            if from.balance == 0.0 || self.getSinkType() != from.getType() {
                return
            }
            let vault <- from.withdraw(amount: from.balance)
            self.pool.borrow()!.deposit(pid: self.positionID, funds: <-vault)
        }
    }

    // DFB.Source implementation for TidalProtocol
    access(all) struct TidalProtocolSource: DFB.Source {
        access(contract) let uniqueID: {DFB.UniqueIdentifier}?
        access(contract) let pool: Capability<auth(EPosition) &Pool>
        access(contract) let positionID: UInt64
        access(contract) let tokenType: Type

        init(pool: Capability<auth(EPosition) &Pool>, positionID: UInt64, tokenType: Type) {
            pre {
                pool.check(): "Invalid Pool Capability provided - cannot construct TidalProtocolSource"
            }
            self.uniqueID = nil
            self.pool = pool
            self.positionID = positionID
            self.tokenType = tokenType
        }

        access(all) view fun getSourceType(): Type {
            return self.tokenType
        }

        access(all) fun minimumAvailable(): UFix64 {
            pre {
                self.pool.check(): "Internal Pool Capability is invalid"
            }
            // Return the available balance for withdrawal
            let position = self.pool.borrow()!.getPositionDetails(pid: self.positionID)
            for balance in position.balances {
                if balance.type == self.tokenType && balance.direction == BalanceDirection.Credit {
                    return balance.balance
                }
            }
            return 0.0
        }

        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            pre {
                self.pool.check(): "Internal Pool Capability is invalid - cannot withdrawAvailable"
            }
            let available = self.minimumAvailable()
            let withdrawAmount = available < maxAmount ? available : maxAmount
            if withdrawAmount > 0.0 {
                return <- self.pool.borrow()!.withdraw(pid: self.positionID, amount: withdrawAmount, type: self.tokenType)
            } else {
                // TODO: Update to use DFBUtils.getEmptyVault method when submodule can be updated against main
                //  |- implies collateral Vaults are checked for FT contract-level implementation before being added to global state
                return <- getAccount(self.tokenType.address!).contracts.borrow<&{FungibleToken}>(
                        name: self.tokenType.contractName!
                    )!.createEmptyVault(vaultType: self.tokenType)
            }
        }
    }

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

    access(self) view fun borrowPool(): auth(EPosition) &Pool {
        return self.account.storage.borrow<auth(EPosition) &Pool>(from: self.PoolStoragePath)
            ?? panic("Could not borrow reference to internal TidalProtocol Pool resource")
    }

    access(self) view fun borrowMOETMinter(): &MOET.Minter {
        return self.account.storage.borrow<&MOET.Minter>(from: MOET.AdminStoragePath)
            ?? panic("Could not borrow reference to internal MOET Minter resource")
    }

    init() {
        self.PoolStoragePath = StoragePath(identifier: "tidalProtocolPool_\(self.account.address)")!
        self.PoolPublicPath = PublicPath(identifier: "tidalProtocolPool_\(self.account.address)")!

        // save Pool in storage & configure public Capability
        self.account.storage.save(
            <-create Pool(defaultToken: Type<@MOET.Vault>(), defaultTokenThreshold: 0.8),
            to: self.PoolStoragePath
        )
        let cap = self.account.capabilities.storage.issue<&Pool>(self.PoolStoragePath)
        self.account.capabilities.unpublish(self.PoolPublicPath)
        self.account.capabilities.publish(cap, at: self.PoolPublicPath)
    }
}
