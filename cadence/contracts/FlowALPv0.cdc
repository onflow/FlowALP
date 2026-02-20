import "Burner"
import "FungibleToken"
import "ViewResolver"

import "DeFiActionsUtils"
import "DeFiActions"
import "MOET"
import "FlowALPMath"
import "FlowALPInterestRates"
import "FlowALPModels"
import "FlowALPEvents"

access(all) contract FlowALPv0 {

    // Design notes: Fixed-point and 128-bit usage:
    // - Interest indices and rates are maintained in 128-bit fixed-point to avoid precision loss during compounding.
    // - External-facing amounts remain UFix64.
    //   Promotions to 128-bit occur only for internal math that multiplies by indices/rates.
    //   This strikes a balance between precision and ergonomics while keeping on-chain math safe.

    /// The canonical StoragePath where the primary FlowALPv0 Pool is stored
    access(all) let PoolStoragePath: StoragePath

    /// The canonical StoragePath where the PoolFactory resource is stored
    access(all) let PoolFactoryPath: StoragePath

    /// The canonical PublicPath where the primary FlowALPv0 Pool can be accessed publicly
    access(all) let PoolPublicPath: PublicPath

    access(all) let PoolCapStoragePath: StoragePath

    /// The canonical StoragePath where PositionManager resources are stored
    access(all) let PositionStoragePath: StoragePath

    /// The canonical PublicPath where PositionManager can be accessed publicly
    access(all) let PositionPublicPath: PublicPath

    /* --- CONSTRUCTS & INTERNAL METHODS ---- */

    /* --- NUMERIC TYPES POLICY ---
        - External/public APIs (Vault amounts, deposits/withdrawals, events) use UFix64.
        - Internal accounting and risk math use UFix128: scaled/true balances, interest indices/rates,
          health factor, and prices once converted.
        Rationale:
        - Interest indices and rates are modeled as 18-decimal fixed-point in FlowALPMath and stored as UFix128.
        - Operating in the UFix128 domain minimizes rounding error in true↔scaled conversions and
          health/price computations.
        - We convert at boundaries via type casting to UFix128 or FlowALPMath.toUFix64.
    */

    ///
    /// Amount of `withdrawSnap` token that can be withdrawn while staying ≥ targetHealth
    access(all) view fun maxWithdraw(
        view: FlowALPModels.PositionView,
        withdrawSnap: FlowALPModels.TokenSnapshot,
        withdrawBal: FlowALPModels.InternalBalance?,
        targetHealth: UFix128
    ): UFix128 {
        let preHealth = FlowALPModels.healthFactor(view: view)
        if preHealth <= targetHealth {
            return 0.0
        }

        // TODO: this logic partly duplicates FlowALPModels.BalanceSheet construction in _getUpdatedBalanceSheet
        // This function differs in that it does not read any data from a Pool resource. Consider consolidating the two implementations.
        var effectiveCollateralTotal: UFix128 = 0.0
        var effectiveDebtTotal: UFix128 = 0.0

        for tokenType in view.balances.keys {
            let balance = view.balances[tokenType]!
            let snap = view.snapshots[tokenType]!

            switch balance.direction {
                case FlowALPModels.BalanceDirection.Credit:
                    let trueBalance = FlowALPMath.scaledBalanceToTrueBalance(
                        balance.scaledBalance,
                        interestIndex: snap.getCreditIndex()
                    )
                    effectiveCollateralTotal = effectiveCollateralTotal
                        + snap.effectiveCollateral(creditBalance: trueBalance)

                case FlowALPModels.BalanceDirection.Debit:
                    let trueBalance = FlowALPMath.scaledBalanceToTrueBalance(
                        balance.scaledBalance,
                        interestIndex: snap.getDebitIndex()
                    )
                    effectiveDebtTotal = effectiveDebtTotal
                        + snap.effectiveDebt(debitBalance: trueBalance)
            }
        }

        let collateralFactor = withdrawSnap.getRisk().getCollateralFactor()
        let borrowFactor = withdrawSnap.getRisk().getBorrowFactor()

        if withdrawBal == nil || withdrawBal!.direction == FlowALPModels.BalanceDirection.Debit {
            // withdrawing increases debt
            let numerator = effectiveCollateralTotal
            let denominatorTarget = numerator / targetHealth
            let deltaDebt = denominatorTarget > effectiveDebtTotal
                ? denominatorTarget - effectiveDebtTotal
                : 0.0 as UFix128
            return (deltaDebt * borrowFactor) / withdrawSnap.getPrice()
        } else {
            // withdrawing reduces collateral
            let trueBalance = FlowALPMath.scaledBalanceToTrueBalance(
                withdrawBal!.scaledBalance,
                interestIndex: withdrawSnap.getCreditIndex()
            )
            let maxPossible = trueBalance
            let requiredCollateral = effectiveDebtTotal * targetHealth
            if effectiveCollateralTotal <= requiredCollateral {
                return 0.0
            }
            let deltaCollateralEffective = effectiveCollateralTotal - requiredCollateral
            let deltaTokens = (deltaCollateralEffective / collateralFactor) / withdrawSnap.getPrice()
            return deltaTokens > maxPossible ? maxPossible : deltaTokens
        }
    }

    /// Pool
    ///
    /// A Pool is the primary logic for protocol operations. It contains the global state of all positions,
    /// credit and debit balances for each supported token type, and reserves as they are deposited to positions.
    access(all) resource Pool {

        /// Pool state (extracted fields)
        access(self) var state: @{FlowALPModels.PoolState}

        /// Individual user positions (stays on Pool because InternalPosition is FlowALPv0-internal)
        access(self) var positions: @{UInt64: {FlowALPModels.InternalPosition}}

        /// Pool Config
        access(self) var config: {FlowALPModels.PoolConfig}

        init(
        	defaultToken: Type,
        	priceOracle: {DeFiActions.PriceOracle},
        	dex: {DeFiActions.SwapperProvider}
        ) {
            pre {
                priceOracle.unitOfAccount() == defaultToken:
                    "Price oracle must return prices in terms of the default token"
            }

            self.state <- FlowALPModels.createPoolState(
                globalLedger: {
                    defaultToken: FlowALPModels.TokenStateImplv1(
                        tokenType: defaultToken,
                        interestCurve: FlowALPInterestRates.FixedCurve(yearlyRate: 0.0),
                        depositRate: 1_000_000.0,        // Default: no rate limiting for default token
                        depositCapacityCap: 1_000_000.0  // Default: high capacity cap
                    )
                },
                reserves: <-{},
                insuranceFund: <-MOET.createEmptyVault(vaultType: Type<@MOET.Vault>()),
                nextPositionID: 0,
                defaultToken: defaultToken,
                stabilityFunds: <-{},
                positionsNeedingUpdates: [],
                positionLock: {}
            )
            self.positions <- {}
            self.config = FlowALPModels.PoolConfigImpl(
                priceOracle: priceOracle,
                collateralFactor: {defaultToken: 1.0},
                borrowFactor: {defaultToken: 1.0},
                positionsProcessedPerCallback: 100,
                liquidationTargetHF: 1.05,
                warmupSec: 300,
                lastUnpausedAt: nil,
                dex: dex,
                dexOracleDeviationBps: 300,
                paused: false,
                debugLogging: false
            )
        }

        // TODO(now): consolidate locking functions.

        /// Marks the position as locked. Panics if the position is already locked.
        access(self) fun _lockPosition(_ pid: UInt64) {
            assert(!self.state.isPositionLocked(pid), message: "Reentrancy: position \(pid) is locked")
            self.state.setPositionLock(pid, true)
        }

        /// Marks the position as unlocked. No-op if the position is already unlocked.
        access(self) fun _unlockPosition(_ pid: UInt64) {
            self.state.removePositionLock(pid)
        }

        /// Locks a position. Used by Position resources to acquire the position lock.
        access(FlowALPModels.EPosition) fun lockPosition(_ pid: UInt64) {
            self._lockPosition(pid)
        }

        /// Unlocks a position. Used by Position resources to release the position lock.
        access(FlowALPModels.EPosition) fun unlockPosition(_ pid: UInt64) {
            self._unlockPosition(pid)
        }

        ///////////////
        // GETTERS
        ///////////////

        /// Returns whether sensitive pool actions are paused by governance,
        /// including withdrawals, deposits, and liquidations
        access(all) view fun isPaused(): Bool {
            return self.config.isPaused()
        }

        /// Returns whether withdrawals and liquidations are paused.
        /// Both have a warmup period after a global pause is ended, to allow users time to improve position health and avoid liquidation.
        /// The warmup period provides an opportunity for users to deposit to unhealthy positions before liquidations start,
        /// and also disallows withdrawing while liquidations are disabled, because liquidations can be needed to satisfy withdrawal requests.
        access(all) view fun isPausedOrWarmup(): Bool {
            if self.isPaused() {
                return true
            }
            if let lastUnpausedAt = self.config.getLastUnpausedAt() {
                let now = UInt64(getCurrentBlock().timestamp)
                return now < lastUnpausedAt + self.config.getWarmupSec()
            }
            return false
        }

        /// Returns an array of the supported token Types
        access(all) view fun getSupportedTokens(): [Type] {
            return self.config.getSupportedTokens()
        }

        /// Returns whether a given token Type is supported or not
        access(all) view fun isTokenSupported(tokenType: Type): Bool {
            return self.config.isTokenSupported(tokenType: tokenType)
        }

        /// Returns the current balance of the stability fund for a given token type.
        /// Returns nil if the token type is not supported.
        access(all) view fun getStabilityFundBalance(tokenType: Type): UFix64? {
            if self.state.hasStabilityFund(tokenType) {
                return self.state.getStabilityFundBalance(tokenType)
            }
            return nil
        }

        /// Returns the stability fee rate for a given token type.
        /// Returns nil if the token type is not supported.
        access(all) view fun getStabilityFeeRate(tokenType: Type): UFix64? {
            if let tokenState = self.state.getTokenState(tokenType) {
                return tokenState.getStabilityFeeRate()
            }

            return nil
        }

        /// Returns the timestamp of the last stability collection for a given token type.
        /// Returns nil if the token type is not supported.
        access(all) view fun getLastStabilityCollectionTime(tokenType: Type): UFix64? {
            if let tokenState = self.state.getTokenState(tokenType) {
                return tokenState.getLastStabilityFeeCollectionTime()
            }

            return nil
        }

        /// Returns whether an insurance swapper is configured for a given token type
        access(all) view fun isInsuranceSwapperConfigured(tokenType: Type): Bool {
            if let tokenState = self.state.getTokenState(tokenType) {
                return tokenState.getInsuranceSwapper() != nil
            }
            return false
        }

        /// Returns the timestamp of the last insurance collection for a given token type
        /// Returns nil if the token type is not supported
        access(all) view fun getLastInsuranceCollectionTime(tokenType: Type): UFix64? {
            if let tokenState = self.state.getTokenState(tokenType) {
                return tokenState.getLastInsuranceCollectionTime()
            }
            return nil
        }

        /// Returns current pause parameters
        access(all) fun getPauseParams(): FlowALPModels.PauseParamsView {
            return FlowALPModels.PauseParamsView(
                paused: self.config.isPaused(),
                warmupSec: self.config.getWarmupSec(),
                lastUnpausedAt: self.config.getLastUnpausedAt(),
            )
        }

        /// Returns current liquidation parameters
        access(all) fun getLiquidationParams(): FlowALPModels.LiquidationParamsView {
            return FlowALPModels.LiquidationParamsView(
                targetHF: self.config.getLiquidationTargetHF(),
                triggerHF: 1.0,
            )
        }

        /// Returns Oracle-DEX guards and allowlists for frontends/keepers
        access(all) fun getDexLiquidationConfig(): {String: AnyStruct} {
            return {
                "dexOracleDeviationBps": self.config.getDexOracleDeviationBps()
            }
        }

        /// Returns true if the position is under the global liquidation trigger (health < 1.0)
        access(all) fun isLiquidatable(pid: UInt64): Bool {
            let health = self.positionHealth(pid: pid)
            return health < 1.0
        }

        /// Returns the current reserve balance for the specified token type.
        access(all) view fun reserveBalance(type: Type): UFix64 {
            return self.state.getReserveBalance(type)
        }

        /// Returns the balance of the MOET insurance fund
        access(all) view fun insuranceFundBalance(): UFix64 {
            return self.state.getInsuranceFundBalance()
        }

        /// Returns the insurance rate for a given token type
        access(all) view fun getInsuranceRate(tokenType: Type): UFix64? {
            if let tokenState = self.state.getTokenState(tokenType) {
                return tokenState.getInsuranceRate()
            }
            
            return nil
        }

        /// Returns a position's balance available for withdrawal of a given Vault type.
        /// Phase 0 refactor: compute via pure helpers using a PositionView and TokenSnapshot for the base path.
        /// When `pullFromTopUpSource` is true and a topUpSource exists, preserve deposit-assisted semantics.
        access(all) fun availableBalance(pid: UInt64, type: Type, pullFromTopUpSource: Bool): UFix64 {
            if self.config.isDebugLogging() {
                log("    [CONTRACT] availableBalance(pid: \(pid), type: \(type.contractName!), pullFromTopUpSource: \(pullFromTopUpSource))")
            }
            let position = self._borrowPosition(pid: pid)

            if pullFromTopUpSource {
                if let topUpSource = position.borrowTopUpSource() {
                    let sourceType = topUpSource.getSourceType()
                    let sourceAmount = topUpSource.minimumAvailable()
                    if self.config.isDebugLogging() {
                        log("    [CONTRACT] Calling to fundsAvailableAboveTargetHealthAfterDepositing with sourceAmount \(sourceAmount) and targetHealth \(position.getMinHealth())")
                    }

                    return self.fundsAvailableAboveTargetHealthAfterDepositing(
                        pid: pid,
                        withdrawType: type,
                        targetHealth: position.getMinHealth(),
                        depositType: sourceType,
                        depositAmount: sourceAmount
                    )
                }
            }

            let view = self.buildPositionView(pid: pid)

            // Build a TokenSnapshot for the requested withdraw type (may not exist in view.snapshots)
            let tokenState = self._borrowUpdatedTokenState(type: type)
            let snap = FlowALPModels.TokenSnapshot(
                price: UFix128(self.config.getPriceOracle().price(ofToken: type)!),
                credit: tokenState.getCreditInterestIndex(),
                debit: tokenState.getDebitInterestIndex(),
                risk: FlowALPModels.RiskParamsImplv1(
                    collateralFactor: UFix128(self.config.getCollateralFactor(tokenType: type)),
                    borrowFactor: UFix128(self.config.getBorrowFactor(tokenType: type)),
                )
            )

            let withdrawBal = view.balances[type]
            let uintMax = FlowALPv0.maxWithdraw(
                view: view,
                withdrawSnap: snap,
                withdrawBal: withdrawBal,
                targetHealth: view.minHealth
            )
            return FlowALPMath.toUFix64Round(uintMax)
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

            for type in position.getBalanceKeys() {
                let balance = position.getBalance(type)!
                let tokenState = self._borrowUpdatedTokenState(type: type)

                let collateralFactor = UFix128(self.config.getCollateralFactor(tokenType: type))
                let borrowFactor = UFix128(self.config.getBorrowFactor(tokenType: type))
                let price = UFix128(self.config.getPriceOracle().price(ofToken: type)!)
                switch balance.direction {
                    case FlowALPModels.BalanceDirection.Credit:
                        let trueBalance = FlowALPMath.scaledBalanceToTrueBalance(
                            balance.scaledBalance,
                            interestIndex: tokenState.getCreditInterestIndex()
                        )

                        let value = price * trueBalance
                        let effectiveCollateralValue = value * collateralFactor
                        effectiveCollateral = effectiveCollateral + effectiveCollateralValue

                    case FlowALPModels.BalanceDirection.Debit:
                        let trueBalance = FlowALPMath.scaledBalanceToTrueBalance(
                            balance.scaledBalance,
                            interestIndex: tokenState.getDebitInterestIndex()
                        )

                        let value = price * trueBalance
                        let effectiveDebtValue = value / borrowFactor
                        effectiveDebt = effectiveDebt + effectiveDebtValue
                }
            }

            // Calculate the health as the ratio of collateral to debt.
            return FlowALPMath.healthComputation(
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
                withdrawType: self.state.getDefaultToken(),
                withdrawAmount: 0.0
            )
        }

        /// Returns the details of a given position as a FlowALPModels.PositionDetails external struct
        access(all) fun getPositionDetails(pid: UInt64): FlowALPModels.PositionDetails {
            if self.config.isDebugLogging() {
                log("    [CONTRACT] getPositionDetails(pid: \(pid))")
            }
            let position = self._borrowPosition(pid: pid)
            let balances: [FlowALPModels.PositionBalance] = []

            for type in position.getBalanceKeys() {
                let balance = position.getBalance(type)!
                let tokenState = self._borrowUpdatedTokenState(type: type)
                let trueBalance = FlowALPMath.scaledBalanceToTrueBalance(
                    balance.scaledBalance,
                    interestIndex: balance.direction == FlowALPModels.BalanceDirection.Credit
                        ? tokenState.getCreditInterestIndex()
                        : tokenState.getDebitInterestIndex()
                )

                balances.append(FlowALPModels.PositionBalance(
                    vaultType: type,
                    direction: balance.direction,
                    balance: FlowALPMath.toUFix64Round(trueBalance)
                ))
            }

            let health = self.positionHealth(pid: pid)
            let defaultTokenAvailable = self.availableBalance(
                pid: pid,
                type: self.state.getDefaultToken(),
                pullFromTopUpSource: false
            )

            return FlowALPModels.PositionDetails(
                balances: balances,
                poolDefaultToken: self.state.getDefaultToken(),
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
                !self.isPausedOrWarmup(): "Liquidations are paused by governance"
                self.isTokenSupported(tokenType: debtType): "Debt token type unsupported: \(debtType.identifier)"
                self.isTokenSupported(tokenType: seizeType): "Collateral token type unsupported: \(seizeType.identifier)"
                debtType == repayment.getType(): "Repayment vault does not match debt type: \(debtType.identifier)!=\(repayment.getType().identifier)"
                // TODO(jord): liquidation paused / post-pause warm
            }
            post {
                !self.state.isPositionLocked(pid): "Position is not unlocked"
            }
            
            self._lockPosition(pid)

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
            let Pd_oracle = self.config.getPriceOracle().price(ofToken: debtType)!  // debt price given by oracle ($/D)
            let Pc_oracle = self.config.getPriceOracle().price(ofToken: seizeType)! // collateral price given by oracle ($/C)
            // Price of collateral, denominated in debt token, implied by oracle (D/C)
            // Oracle says: "1 unit of collateral is worth `Pcd_oracle` units of debt"
            let Pcd_oracle = Pc_oracle / Pd_oracle 

            // Compute the health factor which would result if we were to accept this liquidation
            let Ce_pre = balanceSheet.effectiveCollateral // effective collateral pre-liquidation
            let De_pre = balanceSheet.effectiveDebt       // effective debt pre-liquidation
            let Fc = positionView.snapshots[seizeType]!.getRisk().getCollateralFactor()
            let Fd = positionView.snapshots[debtType]!.getRisk().getBorrowFactor()

            // Ce_seize = effective value of seized collateral ($)
            let Ce_seize = FlowALPMath.effectiveCollateral(credit: UFix128(seizeAmount), price: UFix128(Pc_oracle), collateralFactor: Fc)
            // De_seize = effective value of repaid debt ($)
            let De_seize = FlowALPMath.effectiveDebt(debit: UFix128(repayAmount), price:  UFix128(Pd_oracle), borrowFactor: Fd) 
            let Ce_post = Ce_pre - Ce_seize // position's total effective collateral after liquidation ($)
            let De_post = De_pre - De_seize // position's total effective debt after liquidation ($)
            let postHealth = FlowALPMath.healthComputation(effectiveCollateral: Ce_post, effectiveDebt: De_post)
            assert(postHealth <= self.config.getLiquidationTargetHF(), message: "Liquidation must not exceed target health: post-liquidation health (\(postHealth)) is greater than target health (\(self.config.getLiquidationTargetHF()))")

            // Compare the liquidation offer to liquidation via DEX. If the DEX would provide a better price, reject the offer.
            let swapper = self.config.getSwapperForLiquidation(seizeType: seizeType, debtType: debtType)
            // Get a quote: "how much collateral do I need to give you to get `repayAmount` debt tokens"
            let quote = swapper.quoteIn(forDesired: repayAmount, reverse: false)
            assert(seizeAmount < quote.inAmount, message: "Liquidation offer must be better than that offered by DEX")

            // Compare the DEX price to the oracle price and revert if they diverge beyond configured threshold.
            let Pcd_dex = quote.outAmount / quote.inAmount // price of collateral, denominated in debt token, implied by dex quote (D/C)
            assert(
                FlowALPMath.dexOraclePriceDeviationInRange(dexPrice: Pcd_dex, oraclePrice: Pcd_oracle, maxDeviationBps: self.config.getDexOracleDeviationBps()),
                message: "DEX/oracle price deviation too large. Dex price: \(Pcd_dex), Oracle price: \(Pcd_oracle)")
            // Execute the liquidation
            let seizedCollateral <- self._doLiquidation(pid: pid, repayment: <-repayment, debtType: debtType, seizeType: seizeType, seizeAmount: seizeAmount)
            
            self._unlockPosition(pid)
            
            return <- seizedCollateral
        }

        /// Internal liquidation function which performs a liquidation.
        /// The balance of `repayment` is deposited to the debt token reserve, and `seizeAmount` units of collateral are returned.
        /// Callers are responsible for checking preconditions.
        access(self) fun _doLiquidation(pid: UInt64, repayment: @{FungibleToken.Vault}, debtType: Type, seizeType: Type, seizeAmount: UFix64): @{FungibleToken.Vault} {
            pre {
                !self.isPausedOrWarmup(): "Liquidations are paused by governance"
                // position must have debt and collateral balance 
            }

            let repayAmount = repayment.balance
            assert(repayment.getType() == debtType, message: "Vault type mismatch for repay. Repayment type is \(repayment.getType().identifier) but debt type is \(debtType.identifier)")
            let debtReserveRef = self.state.borrowOrCreateReserve(debtType)
            debtReserveRef.deposit(from: <-repayment)

            // Reduce borrower's debt position by repayAmount
            let position = self._borrowPosition(pid: pid)
            let debtState = self._borrowUpdatedTokenState(type: debtType)

            if position.getBalance(debtType) == nil {
                position.setBalance(debtType, FlowALPModels.InternalBalance(direction: FlowALPModels.BalanceDirection.Debit, scaledBalance: 0.0))
            }
            position.borrowBalance(debtType)!.recordDeposit(amount: UFix128(repayAmount), tokenState: debtState)

            // Withdraw seized collateral from position and send to liquidator
            let seizeState = self._borrowUpdatedTokenState(type: seizeType)
            if position.getBalance(seizeType) == nil {
                position.setBalance(seizeType, FlowALPModels.InternalBalance(direction: FlowALPModels.BalanceDirection.Credit, scaledBalance: 0.0))
            }
            position.borrowBalance(seizeType)!.recordWithdrawal(amount: UFix128(seizeAmount), tokenState: seizeState)
            let seizeReserveRef = self.state.borrowReserve(seizeType)!
            let seizedCollateral <- seizeReserveRef.withdraw(amount: seizeAmount)

            let newHealth = self.positionHealth(pid: pid)
            // TODO: sanity check health here? for auto-liquidating, we may need to perform a bounded search which could result in unbounded error in the final health

            FlowALPEvents.emitLiquidationExecuted(
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
            pre {
                targetHealth >= 1.0: "Target health (\(targetHealth)) must be >=1 after any withdrawal"
            }

            if self.config.isDebugLogging() {
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
            balanceSheet: FlowALPModels.BalanceSheet,
            position: &{FlowALPModels.InternalPosition},
            withdrawType: Type,
            withdrawAmount: UFix64
        ): FlowALPModels.BalanceSheet {
            var effectiveCollateralAfterWithdrawal = balanceSheet.effectiveCollateral
            var effectiveDebtAfterWithdrawal = balanceSheet.effectiveDebt

            if withdrawAmount == 0.0 {
                return FlowALPModels.BalanceSheet(effectiveCollateral: effectiveCollateralAfterWithdrawal, effectiveDebt: effectiveDebtAfterWithdrawal)
            }
            if self.config.isDebugLogging() {
                log("    [CONTRACT] effectiveCollateralAfterWithdrawal: \(effectiveCollateralAfterWithdrawal)")
                log("    [CONTRACT] effectiveDebtAfterWithdrawal: \(effectiveDebtAfterWithdrawal)")
            }

            let withdrawAmountU = UFix128(withdrawAmount)
            let withdrawPrice2 = UFix128(self.config.getPriceOracle().price(ofToken: withdrawType)!)
            let withdrawBorrowFactor2 = UFix128(self.config.getBorrowFactor(tokenType: withdrawType))
            let balance = position.getBalance(withdrawType)
            let direction = balance?.direction ?? FlowALPModels.BalanceDirection.Debit
            let scaledBalance = balance?.scaledBalance ?? 0.0

            switch direction {
                case FlowALPModels.BalanceDirection.Debit:
                    // If the position doesn't have any collateral for the withdrawn token,
                    // we can just compute how much additional effective debt the withdrawal will create.
                    effectiveDebtAfterWithdrawal = balanceSheet.effectiveDebt +
                        (withdrawAmountU * withdrawPrice2) / withdrawBorrowFactor2

                case FlowALPModels.BalanceDirection.Credit:
                    let withdrawTokenState = self._borrowUpdatedTokenState(type: withdrawType)

                    // The user has a collateral position in the given token, we need to figure out if this withdrawal
                    // will flip over into debt, or just draw down the collateral.
                    let trueCollateral = FlowALPMath.scaledBalanceToTrueBalance(
                        scaledBalance,
                        interestIndex: withdrawTokenState.getCreditInterestIndex()
                    )
                    let collateralFactor = UFix128(self.config.getCollateralFactor(tokenType: withdrawType))
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

            return FlowALPModels.BalanceSheet(
                effectiveCollateral: effectiveCollateralAfterWithdrawal,
                effectiveDebt: effectiveDebtAfterWithdrawal
            )
        }

        // TODO(jord): ~100-line function - consider refactoring
        // TODO: documentation
         access(self) fun computeRequiredDepositForHealth(
            position: &{FlowALPModels.InternalPosition},
            depositType: Type,
            withdrawType: Type,
            effectiveCollateral: UFix128,
            effectiveDebt: UFix128,
            targetHealth: UFix128
        ): UFix64 {
            let effectiveCollateralAfterWithdrawal = effectiveCollateral
            var effectiveDebtAfterWithdrawal = effectiveDebt

            if self.config.isDebugLogging() {
                log("    [CONTRACT] effectiveCollateralAfterWithdrawal: \(effectiveCollateralAfterWithdrawal)")
                log("    [CONTRACT] effectiveDebtAfterWithdrawal: \(effectiveDebtAfterWithdrawal)")
            }

            // We now have new effective collateral and debt values that reflect the proposed withdrawal (if any!)
            // Now we can figure out how many of the given token would need to be deposited to bring the position
            // to the target health value.
            var healthAfterWithdrawal = FlowALPMath.healthComputation(
                effectiveCollateral: effectiveCollateralAfterWithdrawal,
                effectiveDebt: effectiveDebtAfterWithdrawal
            )
            if self.config.isDebugLogging() {
                log("    [CONTRACT] healthAfterWithdrawal: \(healthAfterWithdrawal)")
            }

            if healthAfterWithdrawal >= targetHealth {
                // The position is already at or above the target health, so we don't need to deposit anything.
                return 0.0
            }

            // For situations where the required deposit will BOTH pay off debt and accumulate collateral, we keep
            // track of the number of tokens that went towards paying off debt.
            var debtTokenCount: UFix128 = 0.0
            let depositPrice = UFix128(self.config.getPriceOracle().price(ofToken: depositType)!)
            let depositBorrowFactor = UFix128(self.config.getBorrowFactor(tokenType: depositType))
            let withdrawBorrowFactor = UFix128(self.config.getBorrowFactor(tokenType: withdrawType))
            let maybeBalance = position.getBalance(depositType)
            if maybeBalance?.direction == FlowALPModels.BalanceDirection.Debit {
                // The user has a debt position in the given token, we start by looking at the health impact of paying off
                // the entire debt.
                let depositTokenState = self._borrowUpdatedTokenState(type: depositType)
                let debtBalance = maybeBalance!.scaledBalance
                let trueDebtTokenCount = FlowALPMath.scaledBalanceToTrueBalance(
                    debtBalance,
                    interestIndex: depositTokenState.getDebitInterestIndex()
                )
                let debtEffectiveValue = (depositPrice * trueDebtTokenCount) / depositBorrowFactor

                // Ensure we don't underflow - if debtEffectiveValue is greater than effectiveDebtAfterWithdrawal,
                // it means we can pay off all debt
                var effectiveDebtAfterPayment: UFix128 = 0.0
                if debtEffectiveValue <= effectiveDebtAfterWithdrawal {
                    effectiveDebtAfterPayment = effectiveDebtAfterWithdrawal - debtEffectiveValue
                }

                // Check what the new health would be if we paid off all of this debt
                let potentialHealth = FlowALPMath.healthComputation(
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

                    if self.config.isDebugLogging() {
                        log("    [CONTRACT] paybackAmount: \(paybackAmount)")
                    }

                    return FlowALPMath.toUFix64RoundUp(paybackAmount)
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
            let depositCollateralFactor = UFix128(self.config.getCollateralFactor(tokenType: depositType))
            let requiredEffectiveCollateral = (healthChangeU * effectiveDebtAfterWithdrawal) / depositCollateralFactor

            // The amount of the token to deposit, in units of the token.
            let collateralTokenCount = requiredEffectiveCollateral / depositPrice
            if self.config.isDebugLogging() {
                log("    [CONTRACT] requiredEffectiveCollateral: \(requiredEffectiveCollateral)")
                log("    [CONTRACT] collateralTokenCount: \(collateralTokenCount)")
                log("    [CONTRACT] debtTokenCount: \(debtTokenCount)")
                log("    [CONTRACT] collateralTokenCount + debtTokenCount: \(collateralTokenCount) + \(debtTokenCount) = \(collateralTokenCount + debtTokenCount)")
            }

            // debtTokenCount is the number of tokens that went towards debt, zero if there was no debt.
            return FlowALPMath.toUFix64Round(collateralTokenCount + debtTokenCount)
        }

        /// Returns the quantity of the specified token that could be withdrawn
        /// while still keeping the position's health at or above the provided target.
        access(all) fun fundsAvailableAboveTargetHealth(pid: UInt64, type: Type, targetHealth: UFix128): UFix64 {
            return self.fundsAvailableAboveTargetHealthAfterDepositing(
                pid: pid,
                withdrawType: type,
                targetHealth: targetHealth,
                depositType: self.state.getDefaultToken(),
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
            if self.config.isDebugLogging() {
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
            balanceSheet: FlowALPModels.BalanceSheet,
            position: &{FlowALPModels.InternalPosition},
            depositType: Type,
            depositAmount: UFix64
        ): FlowALPModels.BalanceSheet {
            var effectiveCollateralAfterDeposit = balanceSheet.effectiveCollateral
            var effectiveDebtAfterDeposit = balanceSheet.effectiveDebt

            if self.config.isDebugLogging() {
                log("    [CONTRACT] effectiveCollateralAfterDeposit: \(effectiveCollateralAfterDeposit)")
                log("    [CONTRACT] effectiveDebtAfterDeposit: \(effectiveDebtAfterDeposit)")
            }
            if depositAmount == 0.0 {
                return FlowALPModels.BalanceSheet(
                    effectiveCollateral: effectiveCollateralAfterDeposit,
                    effectiveDebt: effectiveDebtAfterDeposit
                )
            }

            let depositAmountCasted = UFix128(depositAmount)
            let depositPriceCasted = UFix128(self.config.getPriceOracle().price(ofToken: depositType)!)
            let depositBorrowFactorCasted = UFix128(self.config.getBorrowFactor(tokenType: depositType))
            let depositCollateralFactorCasted = UFix128(self.config.getCollateralFactor(tokenType: depositType))
            let balance = position.getBalance(depositType)
            let direction = balance?.direction ?? FlowALPModels.BalanceDirection.Credit
            let scaledBalance = balance?.scaledBalance ?? 0.0

            switch direction {
                case FlowALPModels.BalanceDirection.Credit:
                    // If there's no debt for the deposit token,
                    // we can just compute how much additional effective collateral the deposit will create.
                    effectiveCollateralAfterDeposit = balanceSheet.effectiveCollateral +
                        (depositAmountCasted * depositPriceCasted) * depositCollateralFactorCasted

                case FlowALPModels.BalanceDirection.Debit:
                    let depositTokenState = self._borrowUpdatedTokenState(type: depositType)

                    // The user has a debt position in the given token, we need to figure out if this deposit
                    // will result in net collateral, or just bring down the debt.
                    let trueDebt = FlowALPMath.scaledBalanceToTrueBalance(
                        scaledBalance,
                        interestIndex: depositTokenState.getDebitInterestIndex()
                    )
                    if self.config.isDebugLogging() {
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

            if self.config.isDebugLogging() {
                log("    [CONTRACT] effectiveCollateralAfterDeposit: \(effectiveCollateralAfterDeposit)")
                log("    [CONTRACT] effectiveDebtAfterDeposit: \(effectiveDebtAfterDeposit)")
            }

            // We now have new effective collateral and debt values that reflect the proposed deposit (if any!).
            // Now we can figure out how many of the withdrawal token are available while keeping the position
            // at or above the target health value.
            return FlowALPModels.BalanceSheet(
                effectiveCollateral: effectiveCollateralAfterDeposit,
                effectiveDebt: effectiveDebtAfterDeposit
            )
        }

        // Helper function to compute available withdrawal
        // TODO(jord): ~100-line function - consider refactoring
        access(self) fun computeAvailableWithdrawal(
            position: &{FlowALPModels.InternalPosition},
            withdrawType: Type,
            effectiveCollateral: UFix128,
            effectiveDebt: UFix128,
            targetHealth: UFix128
        ): UFix64 {
            var effectiveCollateralAfterDeposit = effectiveCollateral
            let effectiveDebtAfterDeposit = effectiveDebt

            let healthAfterDeposit = FlowALPMath.healthComputation(
                effectiveCollateral: effectiveCollateralAfterDeposit,
                effectiveDebt: effectiveDebtAfterDeposit
            )
            if self.config.isDebugLogging() {
                log("    [CONTRACT] healthAfterDeposit: \(healthAfterDeposit)")
            }

            if healthAfterDeposit <= targetHealth {
                // The position is already at or below the provided target health, so we can't withdraw anything.
                return 0.0
            }

            // For situations where the available withdrawal will BOTH draw down collateral and create debt, we keep
            // track of the number of tokens that are available from collateral
            var collateralTokenCount: UFix128 = 0.0

            let withdrawPrice = UFix128(self.config.getPriceOracle().price(ofToken: withdrawType)!)
            let withdrawCollateralFactor = UFix128(self.config.getCollateralFactor(tokenType: withdrawType))
            let withdrawBorrowFactor = UFix128(self.config.getBorrowFactor(tokenType: withdrawType))

            let maybeBalance = position.getBalance(withdrawType)
            if maybeBalance?.direction == FlowALPModels.BalanceDirection.Credit {
                // The user has a credit position in the withdraw token, we start by looking at the health impact of pulling out all
                // of that collateral
                let withdrawTokenState = self._borrowUpdatedTokenState(type: withdrawType)
                let creditBalance = maybeBalance!.scaledBalance
                let trueCredit = FlowALPMath.scaledBalanceToTrueBalance(
                    creditBalance,
                    interestIndex: withdrawTokenState.getCreditInterestIndex()
                )
                let collateralEffectiveValue = (withdrawPrice * trueCredit) * withdrawCollateralFactor

                // Check what the new health would be if we took out all of this collateral
                let potentialHealth = FlowALPMath.healthComputation(
                    effectiveCollateral: effectiveCollateralAfterDeposit - collateralEffectiveValue, // ??? - why subtract?
                    effectiveDebt: effectiveDebtAfterDeposit
                )

                // Does drawing down all of the collateral go below the target health? Then the max withdrawal comes from collateral only.
                if potentialHealth <= targetHealth {
                    // We will hit the health target before using up all of the withdraw token credit. We can easily
                    // compute how many units of the token would bring the position down to the target health.
                    // We will hit the health target before using up all available withdraw credit.

                    let availableEffectiveValue = effectiveCollateralAfterDeposit - (targetHealth * effectiveDebtAfterDeposit)
                    if self.config.isDebugLogging() {
                        log("    [CONTRACT] availableEffectiveValue: \(availableEffectiveValue)")
                    }

                    // The amount of the token we can take using that amount of health
                    let availableTokenCount = (availableEffectiveValue / withdrawCollateralFactor) / withdrawPrice
                    if self.config.isDebugLogging() {
                        log("    [CONTRACT] availableTokenCount: \(availableTokenCount)")
                    }

                    return FlowALPMath.toUFix64RoundDown(availableTokenCount)
                } else {
                    // We can flip this credit position into a debit position, before hitting the target health.
                    // We have logic below that can determine health changes for debit positions. We've copied it here
                    // with an added handling for the case where the health after deposit is an edgecase
                    collateralTokenCount = trueCredit
                    effectiveCollateralAfterDeposit = effectiveCollateralAfterDeposit - collateralEffectiveValue
                    if self.config.isDebugLogging() {
                        log("    [CONTRACT] collateralTokenCount: \(collateralTokenCount)")
                        log("    [CONTRACT] effectiveCollateralAfterDeposit: \(effectiveCollateralAfterDeposit)")
                    }

                    // We can calculate the available debt increase that would bring us to the target health
                    let availableDebtIncrease = (effectiveCollateralAfterDeposit / targetHealth) - effectiveDebtAfterDeposit
                    let availableTokens = (availableDebtIncrease * withdrawBorrowFactor) / withdrawPrice
                    if self.config.isDebugLogging() {
                        log("    [CONTRACT] availableDebtIncrease: \(availableDebtIncrease)")
                        log("    [CONTRACT] availableTokens: \(availableTokens)")
                        log("    [CONTRACT] availableTokens + collateralTokenCount: \(availableTokens + collateralTokenCount)")
                    }
                    return FlowALPMath.toUFix64RoundDown(availableTokens + collateralTokenCount)
                }
            }

            // At this point, we're either dealing with a position that didn't have a credit balance in the withdraw
            // token, or we've accounted for the credit balance and adjusted the effective collateral above.

            // We can calculate the available debt increase that would bring us to the target health
            let availableDebtIncrease = (effectiveCollateralAfterDeposit / targetHealth) - effectiveDebtAfterDeposit
            let availableTokens = (availableDebtIncrease * withdrawBorrowFactor) / withdrawPrice
            if self.config.isDebugLogging() {
                log("    [CONTRACT] availableDebtIncrease: \(availableDebtIncrease)")
                log("    [CONTRACT] availableTokens: \(availableTokens)")
                log("    [CONTRACT] availableTokens + collateralTokenCount: \(availableTokens + collateralTokenCount)")
            }
            return FlowALPMath.toUFix64RoundDown(availableTokens + collateralTokenCount)
        }

        /// Returns the position's health if the given amount of the specified token were deposited
        access(all) fun healthAfterDeposit(pid: UInt64, type: Type, amount: UFix64): UFix128 {
            let balanceSheet = self._getUpdatedBalanceSheet(pid: pid)
            let position = self._borrowPosition(pid: pid)
            let tokenState = self._borrowUpdatedTokenState(type: type)

            var effectiveCollateralIncrease: UFix128 = 0.0
            var effectiveDebtDecrease: UFix128 = 0.0

            let amountU = UFix128(amount)
            let price = UFix128(self.config.getPriceOracle().price(ofToken: type)!)
            let collateralFactor = UFix128(self.config.getCollateralFactor(tokenType: type))
            let borrowFactor = UFix128(self.config.getBorrowFactor(tokenType: type))
            let balance = position.getBalance(type)
            let direction = balance?.direction ?? FlowALPModels.BalanceDirection.Credit
            let scaledBalance = balance?.scaledBalance ?? 0.0
            switch direction {
                case FlowALPModels.BalanceDirection.Credit:
                    // Since the user has no debt in the given token,
                    // we can just compute how much additional collateral this deposit will create.
                    effectiveCollateralIncrease = (amountU * price) * collateralFactor

                case FlowALPModels.BalanceDirection.Debit:
                    // The user has a debit position in the given token,
                    // we need to figure out if this deposit will only pay off some of the debt,
                    // or if it will also create new collateral.
                    let trueDebt = FlowALPMath.scaledBalanceToTrueBalance(
                        scaledBalance,
                        interestIndex: tokenState.getDebitInterestIndex()
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

            return FlowALPMath.healthComputation(
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
            let price = UFix128(self.config.getPriceOracle().price(ofToken: type)!)
            let collateralFactor = UFix128(self.config.getCollateralFactor(tokenType: type))
            let borrowFactor = UFix128(self.config.getBorrowFactor(tokenType: type))
            let balance = position.getBalance(type)
            let direction = balance?.direction ?? FlowALPModels.BalanceDirection.Debit
            let scaledBalance = balance?.scaledBalance ?? 0.0

            switch direction {
                case FlowALPModels.BalanceDirection.Debit:
                    // The user has no credit position in the given token,
                    // we can just compute how much additional effective debt this withdrawal will create.
                    effectiveDebtIncrease = (amountU * price) / borrowFactor

                case FlowALPModels.BalanceDirection.Credit:
                    // The user has a credit position in the given token,
                    // we need to figure out if this withdrawal will only draw down some of the collateral,
                    // or if it will also create new debt.
                    let trueCredit = FlowALPMath.scaledBalanceToTrueBalance(
                        scaledBalance,
                        interestIndex: tokenState.getCreditInterestIndex()
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

            return FlowALPMath.healthComputation(
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
        ///
        /// Returns a Position resource that provides fine-grained access control through entitlements.
        /// The caller must store the Position resource in their account and manage access to it.
        /// Clients are recommended to use the PositionManager collection type to manage their Positions.
        access(FlowALPModels.EParticipant) fun createPosition(
            funds: @{FungibleToken.Vault},
            issuanceSink: {DeFiActions.Sink},
            repaymentSource: {DeFiActions.Source}?,
            pushToDrawDownSink: Bool
        ): @Position {
            pre {
                !self.isPaused(): "Withdrawal, deposits, and liquidations are paused by governance"
                self.state.getTokenState(funds.getType()) != nil:
                    "Invalid token type \(funds.getType().identifier) - not supported by this Pool"
                self.positionSatisfiesMinimumBalance(type: funds.getType(), balance: UFix128(funds.balance)):
                    "Insufficient funds to create position. Minimum deposit of \(funds.getType().identifier) is \(self.state.getTokenState(funds.getType())!.getMinimumTokenBalancePerPosition())"
                // TODO(jord): Sink/source should be valid
            }
            post {
                !self.state.isPositionLocked(result.id): "Position is not unlocked"
            }
            // construct a new InternalPosition, assigning it the current position ID
            let id = self.state.getNextPositionID()
            self.state.incrementNextPositionID()
            self.positions[id] <-! FlowALPModels.createInternalPosition()

            self._lockPosition(id)

            FlowALPEvents.emitOpened(
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

            // deposit the initial funds
            self._depositEffectsOnly(pid: id, from: <-funds)

            // Rebalancing and queue management
            if pushToDrawDownSink {
                self._rebalancePositionNoLock(pid: id, force: true)
            }

            // Create a capability to the Pool for the Position resource
            // The Pool is stored in the FlowALPv0 contract account
            let poolCap = FlowALPv0.account.capabilities.storage.issue<auth(FlowALPModels.EPosition) &Pool>(
                FlowALPv0.PoolStoragePath
            )

            // Create and return the Position resource

            let position <- create Position(id: id, pool: poolCap)

            self._unlockPosition(id)
            return <-position
        }

        /// Checks if a balance meets the minimum token balance requirement for a given token type.
        ///
        /// This function is used to validate that positions maintain a minimum balance to prevent
        /// dust positions and ensure operational efficiency. The minimum requirement applies to
        /// credit (deposit) balances and is enforced at position creation and during withdrawals.
        ///
        /// @param type: The token type to check (e.g., Type<@FlowToken.Vault>())
        /// @param balance: The balance amount to validate
        /// @return true if the balance meets or exceeds the minimum requirement, false otherwise
        access(self) view fun positionSatisfiesMinimumBalance(type: Type, balance: UFix128): Bool {
            return balance >= UFix128(self.state.getTokenState(type)!.getMinimumTokenBalancePerPosition())
        }

        /// Allows anyone to deposit funds into any position.
        /// If the provided Vault is not supported by the Pool, the operation reverts.
        access(FlowALPModels.EParticipant) fun depositToPosition(pid: UInt64, from: @{FungibleToken.Vault}) {
            pre {
                !self.isPaused(): "Withdrawal, deposits, and liquidations are paused by governance"
            }
            self.depositAndPush(
                pid: pid,
                from: <-from,
                pushToDrawDownSink: false
            )
        }

        /// Applies the state transitions for depositing `from` into `pid`, without doing any of the
        /// surrounding orchestration (locking, health checks, rebalancing, or caller authorization).
        ///
        /// This helper is intentionally effects-only: it *mutates* Pool/Position state and consumes `from`,
        /// but assumes all higher-level preconditions have already been enforced by the caller.
        ///
        /// TODO(jord): ~100-line function - consider refactoring.
        access(self) fun _depositEffectsOnly(
            pid: UInt64,
            from: @{FungibleToken.Vault}
        ) {
            pre {
                !self.isPaused(): "Withdrawal, deposits, and liquidations are paused by governance"
            }
            // NOTE: caller must have already validated pid + token support
            let amount = from.balance
            if amount == 0.0 {
                Burner.burn(<-from)
                return
            }

            // Get a reference to the user's position and global token state for the affected token.
            let type = from.getType()
            let depositedUUID = from.uuid
            let position = self._borrowPosition(pid: pid)
            let tokenState = self._borrowUpdatedTokenState(type: type)

            // Time-based state is handled by the tokenState() helper function

            // Deposit rate limiting: prevent a single large deposit from monopolizing capacity.
            // Excess is queued to be processed asynchronously (see asyncUpdatePosition).
            let depositAmount = from.balance
            let depositLimit = tokenState.depositLimit()

            if depositAmount > depositLimit {
                // The deposit is too big, so we need to queue the excess
                let queuedDeposit <- from.withdraw(amount: depositAmount - depositLimit)

                position.depositToQueue(type, vault: <-queuedDeposit)
            }

            // Per-user deposit limit: check if user has exceeded their per-user limit
            let userDepositLimitCap = tokenState.getUserDepositLimitCap()
            let currentUsage = tokenState.getDepositUsageForPosition(pid)
            let remainingUserLimit = userDepositLimitCap - currentUsage

            // If the deposit would exceed the user's limit, queue or reject the excess
            if from.balance > remainingUserLimit {
                let excessAmount = from.balance - remainingUserLimit
                let queuedForUserLimit <- from.withdraw(amount: excessAmount)

                position.depositToQueue(type, vault: <-queuedForUserLimit)
            }

            // If this position doesn't currently have an entry for this token, create one.
            if position.getBalance(type) == nil {
                position.setBalance(type, FlowALPModels.InternalBalance(
                    direction: FlowALPModels.BalanceDirection.Credit,
                    scaledBalance: 0.0
                ))
            }

            // Create vault if it doesn't exist yet
            if !self.state.hasReserve(type) {
                self.state.initReserve(type, <-from.createEmptyVault())
            }
            let reserveVault = self.state.borrowReserve(type)!

            // Reflect the deposit in the position's balance.
            //
            // This only records the portion of the deposit that was accepted, not any queued portions,
            // as the queued deposits will be processed later (by this function being called again), and therefore
            // will be recorded at that time.
            let acceptedAmount = from.balance
            position.borrowBalance(type)!.recordDeposit(
                amount: UFix128(acceptedAmount),
                tokenState: tokenState
            )

            // Consume deposit capacity for the accepted deposit amount and track per-user usage
            // Only the accepted amount consumes capacity; queued portions will consume capacity when processed later
            tokenState.consumeDepositCapacity(acceptedAmount, pid: pid)

            // Add the money to the reserves
            reserveVault.deposit(from: <-from)

            self._queuePositionForUpdateIfNecessary(pid: pid)

            FlowALPEvents.emitDeposited(
                pid: pid,
                poolUUID: self.uuid,
                vaultType: type,
                amount: amount,
                depositedUUID: depositedUUID
            )

        }

        /// Deposits the provided funds to the specified position with the configurable `pushToDrawDownSink` option.
        /// If `pushToDrawDownSink` is true, excess value putting the position above its max health
        /// is pushed to the position's configured `drawDownSink`.
        access(FlowALPModels.EPosition) fun depositAndPush(
            pid: UInt64,
            from: @{FungibleToken.Vault},
            pushToDrawDownSink: Bool
        ) {
            pre {
                !self.isPaused(): "Withdrawal, deposits, and liquidations are paused by governance"
                self.positions[pid] != nil:
                    "Invalid position ID \(pid) - could not find an InternalPosition with the requested ID in the Pool"
                self.state.getTokenState(from.getType()) != nil:
                    "Invalid token type \(from.getType().identifier) - not supported by this Pool"
            }
            post {
                !self.state.isPositionLocked(pid): "Position is not unlocked"
            }
            if self.config.isDebugLogging() {
                log("    [CONTRACT] depositAndPush(pid: \(pid), pushToDrawDownSink: \(pushToDrawDownSink))")
            }

            self._lockPosition(pid)

            self._depositEffectsOnly(pid: pid, from: <-from)

            // Rebalancing and queue management
            if pushToDrawDownSink {
                self._rebalancePositionNoLock(pid: pid, force: true)
            }

            self._unlockPosition(pid)
        }

        /// Withdraws the requested funds from the specified position.
        ///
        /// Callers should be careful that the withdrawal does not put their position under its target health,
        /// especially if the position doesn't have a configured `topUpSource` from which to repay borrowed funds
        /// in the event of undercollaterlization.
        access(FlowALPModels.EPosition) fun withdraw(pid: UInt64, amount: UFix64, type: Type): @{FungibleToken.Vault} {
            pre {
                !self.isPausedOrWarmup(): "Withdrawals are paused by governance"
            }
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
        access(FlowALPModels.EPosition) fun withdrawAndPull(
            pid: UInt64,
            type: Type,
            amount: UFix64,
            pullFromTopUpSource: Bool
        ): @{FungibleToken.Vault} {
            pre {
                !self.isPausedOrWarmup(): "Withdrawals are paused by governance"
                self.positions[pid] != nil:
                    "Invalid position ID \(pid) - could not find an InternalPosition with the requested ID in the Pool"
                self.state.getTokenState(type) != nil:
                    "Invalid token type \(type.identifier) - not supported by this Pool"
            }
            post {
                !self.state.isPositionLocked(pid): "Position is not unlocked"
            }
            self._lockPosition(pid)
            if self.config.isDebugLogging() {
                log("    [CONTRACT] withdrawAndPull(pid: \(pid), type: \(type.identifier), amount: \(amount), pullFromTopUpSource: \(pullFromTopUpSource))")
            }
            if amount == 0.0 {
                self._unlockPosition(pid)
                return <- DeFiActionsUtils.getEmptyVault(type)
            }

            // Get a reference to the user's position and global token state for the affected token.
            let position = self._borrowPosition(pid: pid)
            let tokenState = self._borrowUpdatedTokenState(type: type)

            // Global interest indices are updated via tokenState() helper

            // Preflight to see if the funds are available
            let topUpSource = position.borrowTopUpSource()
            let topUpType = topUpSource?.getSourceType() ?? self.state.getDefaultToken()

            let requiredDeposit = self.fundsRequiredForTargetHealthAfterWithdrawing(
                pid: pid,
                depositType: topUpType,
                targetHealth: position.getMinHealth(),
                withdrawType: type,
                withdrawAmount: amount
            )

            var canWithdraw = false

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
                        targetHealth: position.getTargetHealth(),
                        withdrawType: type,
                        withdrawAmount: amount
                    )

                    let pulledVault <- topUpSource.withdrawAvailable(maxAmount: idealDeposit)
                    assert(pulledVault.getType() == topUpType, message: "topUpSource returned unexpected token type")
                    let pulledAmount = pulledVault.balance


                    // NOTE: We requested the "ideal" deposit, but we compare against the required deposit here.
                    // The top up source may not have enough funds get us to the target health, but could have
                    // enough to keep us over the minimum.
                    if pulledAmount >= requiredDeposit {
                        // We can service this withdrawal if we deposit funds from our top up source
                        self._depositEffectsOnly(
                            pid: pid,
                            from: <-pulledVault
                        )
                        canWithdraw = true
                    } else {
                        // We can't get the funds required to service this withdrawal, so we need to redeposit what we got
                        self._depositEffectsOnly(
                            pid: pid,
                            from: <-pulledVault
                        )
                    }
                }
            }

            if !canWithdraw {
                // Log detailed information about the failed withdrawal (only if debugging enabled)
                if self.config.isDebugLogging() {
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
            if position.getBalance(type) == nil {
                position.setBalance(type, FlowALPModels.InternalBalance(
                    direction: FlowALPModels.BalanceDirection.Credit,
                    scaledBalance: 0.0
                ))
            }

            let reserveVault = self.state.borrowReserve(type)!

            // Reflect the withdrawal in the position's balance
            let uintAmount = UFix128(amount)
            position.borrowBalance(type)!.recordWithdrawal(
                amount: uintAmount,
                tokenState: tokenState
            )
            // Attempt to pull additional collateral from the top-up source (if configured)
            // to keep the position above minHealth after the withdrawal.
            // Regardless of whether a top-up occurs, the position must be healthy post-withdrawal.
            let postHealth = self.positionHealth(pid: pid)
            assert(
                postHealth >= 1.0,
                message: "Post-withdrawal position health (\(postHealth)) is unhealthy"
            )

            // Ensure that the remaining balance meets the minimum requirement (or is zero)
            // Building the position view does require copying the balances, so it's less efficient than accessing the balance directly.
            // Since most positions will have a single token type, we're okay with this for now.
            let positionView = self.buildPositionView(pid: pid)
            let remainingBalance = positionView.trueBalance(ofToken: type)

            // This is applied to both credit and debit balances, with the main goal being to avoid dust positions.
            assert(
                remainingBalance == 0.0 || self.positionSatisfiesMinimumBalance(type: type, balance: remainingBalance),
                message: "Withdrawal would leave position below minimum balance requirement of \(self.state.getTokenState(type)!.getMinimumTokenBalancePerPosition()). Remaining balance would be \(remainingBalance)."
            )

            // Queue for update if necessary
            self._queuePositionForUpdateIfNecessary(pid: pid)

            let withdrawn <- reserveVault.withdraw(amount: amount)

            FlowALPEvents.emitWithdrawn(
                pid: pid,
                poolUUID: self.uuid,
                vaultType: type,
                amount: withdrawn.balance,
                withdrawnUUID: withdrawn.uuid
            )

            self._unlockPosition(pid)
            return <- withdrawn
        }

        ///////////////////////
        // POOL MANAGEMENT
        ///////////////////////

        /// Returns a mutable reference to the pool's configuration.
        /// Use this to update config fields that don't require events or side effects.
        access(FlowALPModels.EGovernance) fun borrowConfig(): &{FlowALPModels.PoolConfig} {
            return &self.config
        }

        /// Pauses the pool, temporarily preventing further withdrawals, deposits, and liquidations
        access(FlowALPModels.EGovernance) fun pausePool() {
            if self.config.isPaused() {
                return
            }
            self.config.setPaused(true)
            FlowALPEvents.emitPoolPaused(poolUUID: self.uuid)
        }

        /// Unpauses the pool, and starts the warm-up window
        access(FlowALPModels.EGovernance) fun unpausePool() {
            if !self.config.isPaused() {
                return
            }
            self.config.setPaused(false)
            let now = UInt64(getCurrentBlock().timestamp)
            self.config.setLastUnpausedAt(now)
            FlowALPEvents.emitPoolUnpaused(
                poolUUID: self.uuid,
                warmupEndsAt: now + self.config.getWarmupSec()
            )
        }

        /// Adds a new token type to the pool with the given parameters defining borrowing limits on collateral,
        /// interest accumulation, deposit rate limiting, and deposit size capacity
        access(FlowALPModels.EGovernance) fun addSupportedToken(
            tokenType: Type,
            collateralFactor: UFix64,
            borrowFactor: UFix64,
            interestCurve: {FlowALPInterestRates.InterestCurve},
            depositRate: UFix64,
            depositCapacityCap: UFix64
        ) {
            pre {
                self.state.getTokenState(tokenType) == nil:
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
            self.state.setTokenState(tokenType, FlowALPModels.TokenStateImplv1(
                tokenType: tokenType,
                interestCurve: interestCurve,
                depositRate: depositRate,
                depositCapacityCap: depositCapacityCap
            ))

            // Set collateral factor (what percentage of value can be used as collateral)
            self.config.setCollateralFactor(tokenType: tokenType, factor: collateralFactor)

            // Set borrow factor (risk adjustment for borrowed amounts)
            self.config.setBorrowFactor(tokenType: tokenType, factor: borrowFactor)
        }

        /// Updates the insurance rate for a given token (fraction in [0,1])
        access(FlowALPModels.EGovernance) fun setInsuranceRate(tokenType: Type, insuranceRate: UFix64) {
            pre {
                self.isTokenSupported(tokenType: tokenType):
                    "Unsupported token type \(tokenType.identifier)"
                insuranceRate >= 0.0 && insuranceRate < 1.0:
                    "insuranceRate must be in range [0, 1)"
                insuranceRate + (self.getStabilityFeeRate(tokenType: tokenType) ?? 0.0) < 1.0:
                    "insuranceRate + stabilityFeeRate must be in range [0, 1) to avoid underflow in credit rate calculation"
            }
            let tsRef = self.state.borrowTokenState(tokenType)
                ?? panic("Invariant: token state missing")

            // Validate constraint: non-zero rate requires swapper
            if insuranceRate > 0.0 {
                assert(
                    tsRef.getInsuranceSwapper() != nil, 
                    message:"Cannot set non-zero insurance rate without an insurance swapper configured for \(tokenType.identifier)",
                )
            }
            tsRef.setInsuranceRate(insuranceRate)

            FlowALPEvents.emitInsuranceRateUpdated(
                poolUUID: self.uuid,
                tokenType: tokenType.identifier,
                insuranceRate: insuranceRate
            )
        }

        /// Sets the insurance swapper for a given token type (must swap from tokenType to MOET)
        access(FlowALPModels.EGovernance) fun setInsuranceSwapper(tokenType: Type, swapper: {DeFiActions.Swapper}?) {
            pre {
                self.isTokenSupported(tokenType: tokenType): "Unsupported token type"
            }
            let tsRef = self.state.borrowTokenState(tokenType)
                ?? panic("Invariant: token state missing")   

            if let swapper = swapper {
                // Validate swapper types match
                assert(swapper.inType() == tokenType, message: "Swapper input type must match token type")
                assert(swapper.outType() == Type<@MOET.Vault>(), message: "Swapper output type must be MOET")
            
            } else {
                // cannot remove swapper if insurance rate > 0
                assert(
                    tsRef.getInsuranceRate() == 0.0,
                    message: "Cannot remove insurance swapper while insurance rate is non-zero for \(tokenType.identifier)"
                )
            }

            tsRef.setInsuranceSwapper(swapper)
        }

        /// Manually triggers insurance collection for a given token type.
        /// This is useful for governance to collect accrued insurance on-demand.
        /// Insurance is calculated based on time elapsed since last collection.
        access(FlowALPModels.EGovernance) fun collectInsurance(tokenType: Type) {
            pre {
                self.isTokenSupported(tokenType: tokenType): "Unsupported token type"
            }
            self.updateInterestRatesAndCollectInsurance(tokenType: tokenType)
        }

        /// Updates the per-deposit limit fraction for a given token (fraction in [0,1])
        access(FlowALPModels.EGovernance) fun setDepositLimitFraction(tokenType: Type, fraction: UFix64) {
            pre {
                self.isTokenSupported(tokenType: tokenType):
                    "Unsupported token type \(tokenType.identifier)"
                fraction > 0.0 && fraction <= 1.0:
                    "fraction must be in (0,1]"
            }
            let tsRef = self.state.borrowTokenState(tokenType)
                ?? panic("Invariant: token state missing")
            tsRef.setDepositLimitFraction(fraction)
        }

        /// Updates the deposit rate for a given token (tokens per hour)
        access(FlowALPModels.EGovernance) fun setDepositRate(tokenType: Type, hourlyRate: UFix64) {
            pre {
                self.isTokenSupported(tokenType: tokenType): "Unsupported token type"
            }
            let tsRef = self.state.borrowTokenState(tokenType)
                ?? panic("Invariant: token state missing")
            tsRef.setDepositRate(hourlyRate)
        }

        /// Updates the deposit capacity cap for a given token
        access(FlowALPModels.EGovernance) fun setDepositCapacityCap(tokenType: Type, cap: UFix64) {
            pre {
                self.isTokenSupported(tokenType: tokenType): "Unsupported token type"
            }
            let tsRef = self.state.borrowTokenState(tokenType)
                ?? panic("Invariant: token state missing")
            tsRef.setDepositCapacityCap(cap)
        }

        /// Updates the minimum token balance per position for a given token
        access(FlowALPModels.EGovernance) fun setMinimumTokenBalancePerPosition(tokenType: Type, minimum: UFix64) {
            pre {
                self.isTokenSupported(tokenType: tokenType): "Unsupported token type"
            }
            let tsRef = self.state.borrowTokenState(tokenType)
                ?? panic("Invariant: token state missing")
            tsRef.setMinimumTokenBalancePerPosition(minimum)
        }

        /// Updates the stability fee rate for a given token (fraction in [0,1]).
        ///
        /// @param tokenTypeIdentifier: The fully qualified type identifier of the token (e.g., "A.0x1.FlowToken.Vault")
        /// @param stabilityFeeRate: The fee rate as a fraction in [0, 1]
        ///
        ///
        /// Emits: StabilityFeeRateUpdated
        access(FlowALPModels.EGovernance) fun setStabilityFeeRate(tokenType: Type, stabilityFeeRate: UFix64) {
            pre {
                self.isTokenSupported(tokenType: tokenType):
                    "Unsupported token type \(tokenType.identifier)"
                stabilityFeeRate >= 0.0 && stabilityFeeRate < 1.0:
                    "stability fee rate must be in range [0, 1)"
                stabilityFeeRate + (self.getInsuranceRate(tokenType: tokenType) ?? 0.0) < 1.0:
                    "stabilityFeeRate + insuranceRate must be in range [0, 1) to avoid underflow in credit rate calculation"
            }
            let tsRef = self.state.borrowTokenState(tokenType)
                ?? panic("Invariant: token state missing")
            tsRef.setStabilityFeeRate(stabilityFeeRate)
            
            FlowALPEvents.emitStabilityFeeRateUpdated(
                poolUUID: self.uuid,
                tokenType: tokenType.identifier,
                stabilityFeeRate: stabilityFeeRate
            )
        }

        /// Withdraws stability funds collected from the stability fee for a given token
        ///
        /// Emits: StabilityFundWithdrawn
        access(FlowALPModels.EGovernance) fun withdrawStabilityFund(tokenType: Type, amount: UFix64, recipient: &{FungibleToken.Receiver}) {
            pre {
                self.state.hasStabilityFund(tokenType): "No stability fund exists for token type \(tokenType.identifier)"
                amount > 0.0: "Withdrawal amount must be positive"
            }
            let fundRef = self.state.borrowStabilityFund(tokenType)!
            assert(
                fundRef.balance >= amount,
                message: "Insufficient stability fund balance. Available: \(fundRef.balance), requested: \(amount)"
            )
            
            let withdrawn <- fundRef.withdraw(amount: amount)
            recipient.deposit(from: <-withdrawn)

            FlowALPEvents.emitStabilityFundWithdrawn(
                poolUUID: self.uuid,
                tokenType: tokenType.identifier,
                amount: amount
            )
        }

        /// Manually triggers fee collection for a given token type.
        /// This is useful for governance to collect accrued stability on-demand.
        /// Fee is calculated based on time elapsed since last collection.
        access(FlowALPModels.EGovernance) fun collectStability(tokenType: Type) {
            pre {
                self.isTokenSupported(tokenType: tokenType): "Unsupported token type"
            }
            self.updateInterestRatesAndCollectStability(tokenType: tokenType)
        }

        /// Regenerates deposit capacity for all supported token types
        /// Each token type's capacity regenerates independently based on its own depositRate,
        /// approximately once per hour, up to its respective depositCapacityCap
        /// When capacity regenerates, user deposit usage is reset for that token type
        access(FlowALPModels.EImplementation) fun regenerateAllDepositCapacities() {
            for tokenType in self.state.getGlobalLedgerKeys() {
                let tsRef = self.state.borrowTokenState(tokenType)
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
        access(FlowALPModels.EGovernance) fun setInterestCurve(tokenType: Type, interestCurve: {FlowALPInterestRates.InterestCurve}) {
            pre {
                self.isTokenSupported(tokenType: tokenType): "Unsupported token type"
            }
            // First, update interest indices to compound any accrued interest at the OLD rate
            // This "finalizes" all interest accrued up to this moment before switching curves
            let tsRef = self._borrowUpdatedTokenState(type: tokenType)
            // Now safe to set the new curve - subsequent interest will accrue at the new rate
            tsRef.setInterestCurve(interestCurve)
            FlowALPEvents.emitInterestCurveUpdated(
                poolUUID: self.uuid,
                tokenType: tokenType.identifier,
                curveType: interestCurve.getType().identifier
            )
        }

        /// Rebalances the position to the target health value, if the position is under- or over-collateralized,
        /// as defined by the position-specific min/max health thresholds.
        /// If force=true, the position will be rebalanced regardless of its current health.
        ///
        /// When rebalancing, funds are withdrawn from the position's topUpSource or deposited to its drawDownSink.
        /// Rebalancing is done on a best effort basis (even when force=true). If the position has no sink/source,
        /// of either cannot accept/provide sufficient funds for rebalancing, the rebalance will still occur but will
        /// not cause the position to reach its target health.
        access(FlowALPModels.EPosition | FlowALPModels.ERebalance) fun rebalancePosition(pid: UInt64, force: Bool) {
            pre {
                !self.isPaused(): "Withdrawal, deposits, and liquidations are paused by governance"
            }
            post {
                !self.state.isPositionLocked(pid): "Position is not unlocked"
            }
            self._lockPosition(pid)
            self._rebalancePositionNoLock(pid: pid, force: force)
            self._unlockPosition(pid)
        }

        /// Attempts to rebalance a position toward its configured `targetHealth` without acquiring
        /// or releasing the position lock. This function performs *best-effort* rebalancing and may
        /// partially rebalance or no-op depending on available sinks/sources and their capacity.
        ///
        /// This helper is intentionally "no-lock" and "effects-only" with respect to orchestration.
        /// Callers are responsible for acquiring and releasing the position lock and for enforcing
        /// any higher-level invariants.
        access(self) fun _rebalancePositionNoLock(pid: UInt64, force: Bool) {
            pre {
                !self.isPaused(): "Withdrawal, deposits, and liquidations are paused by governance"
            }
            if self.config.isDebugLogging() {
                log("    [CONTRACT] rebalancePosition(pid: \(pid), force: \(force))")
            }
            let position = self._borrowPosition(pid: pid)
            let balanceSheet = self._getUpdatedBalanceSheet(pid: pid)

            if !force && (position.getMinHealth() <= balanceSheet.health && balanceSheet.health <= position.getMaxHealth()) {
                // We aren't forcing the update, and the position is already between its desired min and max. Nothing to do!
                return
            }

            if balanceSheet.health < position.getTargetHealth() {
                // The position is undercollateralized,
                // see if the source can get more collateral to bring it up to the target health.
                if let topUpSource = position.borrowTopUpSource() {
                    let idealDeposit = self.fundsRequiredForTargetHealth(
                        pid: pid,
                        type: topUpSource.getSourceType(),
                        targetHealth: position.getTargetHealth()
                    )
                    if self.config.isDebugLogging() {
                        log("    [CONTRACT] idealDeposit: \(idealDeposit)")
                    }

                    let topUpType = topUpSource.getSourceType()
                    let pulledVault <- topUpSource.withdrawAvailable(maxAmount: idealDeposit)
                    assert(pulledVault.getType() == topUpType, message: "topUpSource returned unexpected token type")

                    FlowALPEvents.emitRebalanced(
                        pid: pid,
                        poolUUID: self.uuid,
                        atHealth: balanceSheet.health,
                        amount: pulledVault.balance,
                        fromUnder: true
                        )

                    self._depositEffectsOnly(
                        pid: pid,
                        from: <-pulledVault,
                    )
                }
            } else if balanceSheet.health > position.getTargetHealth() {
                // The position is overcollateralized,
                // we'll withdraw funds to match the target health and offer it to the sink.
                if self.isPausedOrWarmup() {
                    // Withdrawals (including pushing to the drawDownSink) are disabled during the warmup period
                    return
                }
                if let drawDownSink = position.borrowDrawDownSink() {
                    let sinkType = drawDownSink.getSinkType()
                    let idealWithdrawal = self.fundsAvailableAboveTargetHealth(
                        pid: pid,
                        type: sinkType,
                        targetHealth: position.getTargetHealth()
                    )
                    if self.config.isDebugLogging() {
                        log("    [CONTRACT] idealWithdrawal: \(idealWithdrawal)")
                    }

                    // Compute how many tokens of the sink's type are available to hit our target health.
                    let sinkCapacity = drawDownSink.minimumCapacity()
                    let sinkAmount = (idealWithdrawal > sinkCapacity) ? sinkCapacity : idealWithdrawal

                    // TODO(jord): we enforce in setDrawDownSink that the type is MOET -> we should panic here if that does not hold (currently silently fail)
                    if sinkAmount > 0.0 && sinkType == Type<@MOET.Vault>() {
                        let tokenState = self._borrowUpdatedTokenState(type: Type<@MOET.Vault>())
                        if position.getBalance(Type<@MOET.Vault>()) == nil {
                            position.setBalance(Type<@MOET.Vault>(), FlowALPModels.InternalBalance(
                                direction: FlowALPModels.BalanceDirection.Credit,
                                scaledBalance: 0.0
                            ))
                        }
                        // record the withdrawal and mint the tokens
                        let uintSinkAmount = UFix128(sinkAmount)
                        position.borrowBalance(Type<@MOET.Vault>())!.recordWithdrawal(
                            amount: uintSinkAmount,
                            tokenState: tokenState
                        )
                        let sinkVault <- FlowALPv0._borrowMOETMinter().mintTokens(amount: sinkAmount)

                        FlowALPEvents.emitRebalanced(
                            pid: pid,
                            poolUUID: self.uuid,
                            atHealth: balanceSheet.health,
                            amount: sinkVault.balance,
                            fromUnder: false
                        )

                        // Push what we can into the sink, and redeposit the rest
                        drawDownSink.depositCapacity(from: &sinkVault as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})
                        if sinkVault.balance > 0.0 {
                            self._depositEffectsOnly(
                                pid: pid,
                                from: <-sinkVault,
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
        access(FlowALPModels.EImplementation) fun asyncUpdate() {
            pre {
                !self.isPaused(): "Withdrawal, deposits, and liquidations are paused by governance"
            }
            // TODO: In the production version, this function should only process some positions (limited by positionsProcessedPerCallback) AND
            // it should schedule each update to run in its own callback, so a revert() call from one update (for example, if a source or
            // sink aborts) won't prevent other positions from being updated.
            var processed: UInt64 = 0
            while self.state.getPositionsNeedingUpdatesLength() > 0 && processed < self.config.getPositionsProcessedPerCallback() {
                let pid = self.state.removeFirstPositionNeedingUpdate()
                self.asyncUpdatePosition(pid: pid)
                self._queuePositionForUpdateIfNecessary(pid: pid)
                processed = processed + 1
            }
        }

        /// Executes an asynchronous update on the specified position
        access(FlowALPModels.EImplementation) fun asyncUpdatePosition(pid: UInt64) {
            pre {
                !self.isPaused(): "Withdrawal, deposits, and liquidations are paused by governance"
            }
            post {
                !self.state.isPositionLocked(pid): "Position is not unlocked"
            }
            self._lockPosition(pid)
            let position = self._borrowPosition(pid: pid)

            // store types to avoid iterating while mutating
            let depositTypes = position.getQueuedDepositKeys()
            // First check queued deposits, their addition could affect the rebalance we attempt later
            for depositType in depositTypes {
                let queuedVault <- position.removeQueuedDeposit(depositType)!
                let queuedAmount = queuedVault.balance
                let depositTokenState = self._borrowUpdatedTokenState(type: depositType)
                let maxDeposit = depositTokenState.depositLimit()

                if maxDeposit >= queuedAmount {
                    // We can deposit all of the queued deposit, so just do it and remove it from the queue

                    self._depositEffectsOnly(pid: pid, from: <-queuedVault)
                } else {
                    // We can only deposit part of the queued deposit, so do that and leave the rest in the queue
                    // for the next time we run.
                    let depositVault <- queuedVault.withdraw(amount: maxDeposit)
                    self._depositEffectsOnly(pid: pid, from: <-depositVault)

                    // We need to update the queued vault to reflect the amount we used up
                    position.depositToQueue(depositType, vault: <-queuedVault)
                }
            }

            // Now that we've deposited a non-zero amount of any queued deposits, we can rebalance
            // the position if necessary.
            self._rebalancePositionNoLock(pid: pid, force: false)
            self._unlockPosition(pid)
        }

        /// Updates interest rates for a token and collects stability fee.
        /// This method should be called periodically to ensure rates are current and fee amounts are collected.
        ///
        /// @param tokenType: The token type to update rates for
        access(self) fun updateInterestRatesAndCollectStability(tokenType: Type) {
            let tokenState = self._borrowUpdatedTokenState(type: tokenType)
            tokenState.updateInterestRates()

            // Ensure reserves exist for this token type
            if !self.state.hasReserve(tokenType) {
                return
            }

            // Get reference to reserves
            let reserveRef = self.state.borrowReserve(tokenType)!

            // Collect stability and get token vault
            if let collectedVault <- self._collectStability(tokenState: tokenState, reserveVault: reserveRef) {
                let collectedBalance = collectedVault.balance
                // Deposit collected token into stability fund
                if !self.state.hasStabilityFund(tokenType) {
                    self.state.initStabilityFund(tokenType, <-collectedVault)
                } else {
                    let fundRef = self.state.borrowStabilityFund(tokenType)!
                    fundRef.deposit(from: <-collectedVault)
                }

                FlowALPEvents.emitStabilityFeeCollected(
                    poolUUID: self.uuid,
                    tokenType: tokenType.identifier,
                    stabilityAmount: collectedBalance,
                    collectionTime: tokenState.getLastStabilityFeeCollectionTime()
                )
            }
        }

        /// Collects insurance by withdrawing from reserves and swapping to MOET.
        access(self) fun _collectInsurance(
            tokenState: &{FlowALPModels.TokenState},
            reserveVault: auth(FungibleToken.Withdraw) &{FungibleToken.Vault},
            oraclePrice: UFix64,
            maxDeviationBps: UInt16
        ): @MOET.Vault? {
            let currentTime = getCurrentBlock().timestamp

            if tokenState.getInsuranceRate() == 0.0 {
                tokenState.setLastInsuranceCollectionTime(currentTime)
                return nil
            }

            let timeElapsed = currentTime - tokenState.getLastInsuranceCollectionTime()
            if timeElapsed <= 0.0 {
                return nil
            }

            let debitIncome = tokenState.getTotalDebitBalance() * (FlowALPMath.powUFix128(tokenState.getCurrentDebitRate(), timeElapsed) - 1.0)
            let insuranceAmount = debitIncome * UFix128(tokenState.getInsuranceRate())
            let insuranceAmountUFix64 = FlowALPMath.toUFix64RoundDown(insuranceAmount)

            if insuranceAmountUFix64 == 0.0 {
                tokenState.setLastInsuranceCollectionTime(currentTime)
                return nil
            }

            if reserveVault.balance == 0.0 {
                tokenState.setLastInsuranceCollectionTime(currentTime)
                return nil
            }

            let amountToCollect = insuranceAmountUFix64 > reserveVault.balance ? reserveVault.balance : insuranceAmountUFix64
            var insuranceVault <- reserveVault.withdraw(amount: amountToCollect)

            let insuranceSwapper = tokenState.getInsuranceSwapper() ?? panic("missing insurance swapper")

            assert(insuranceSwapper.inType() == reserveVault.getType(), message: "Insurance swapper input type must be same as reserveVault")
            assert(insuranceSwapper.outType() == Type<@MOET.Vault>(), message: "Insurance swapper must output MOET")

            let quote = insuranceSwapper.quoteOut(forProvided: amountToCollect, reverse: false)
            let dexPrice = quote.outAmount / quote.inAmount
            assert(
                FlowALPMath.dexOraclePriceDeviationInRange(dexPrice: dexPrice, oraclePrice: oraclePrice, maxDeviationBps: maxDeviationBps),
                message: "DEX/oracle price deviation too large. Dex price: \(dexPrice), Oracle price: \(oraclePrice)")
            var moetVault <- insuranceSwapper.swap(quote: quote, inVault: <-insuranceVault) as! @MOET.Vault

            tokenState.setLastInsuranceCollectionTime(currentTime)
            return <-moetVault
        }

        /// Collects stability funds by withdrawing from reserves.
        access(self) fun _collectStability(
            tokenState: &{FlowALPModels.TokenState},
            reserveVault: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}
        ): @{FungibleToken.Vault}? {
            let currentTime = getCurrentBlock().timestamp

            if tokenState.getStabilityFeeRate() == 0.0 {
                tokenState.setLastStabilityFeeCollectionTime(currentTime)
                return nil
            }

            let timeElapsed = currentTime - tokenState.getLastStabilityFeeCollectionTime()
            if timeElapsed <= 0.0 {
                return nil
            }

            let stabilityFeeRate = UFix128(tokenState.getStabilityFeeRate())
            let interestIncome = tokenState.getTotalDebitBalance() * (FlowALPMath.powUFix128(tokenState.getCurrentDebitRate(), timeElapsed) - 1.0)
            let stabilityAmount = interestIncome * stabilityFeeRate
            let stabilityAmountUFix64 = FlowALPMath.toUFix64RoundDown(stabilityAmount)

            if stabilityAmountUFix64 == 0.0 {
                tokenState.setLastStabilityFeeCollectionTime(currentTime)
                return nil
            }

            if reserveVault.balance == 0.0 {
                tokenState.setLastStabilityFeeCollectionTime(currentTime)
                return nil
            }

            let reserveVaultBalance = reserveVault.balance
            let amountToCollect = stabilityAmountUFix64 > reserveVaultBalance ? reserveVaultBalance : stabilityAmountUFix64
            let stabilityVault <- reserveVault.withdraw(amount: amountToCollect)

            tokenState.setLastStabilityFeeCollectionTime(currentTime)
            return <-stabilityVault
        }

        ////////////////
        // INTERNAL
        ////////////////

        /// Queues a position for asynchronous updates if the position has been marked as requiring an update
        access(self) fun _queuePositionForUpdateIfNecessary(pid: UInt64) {
            if self.state.positionsNeedingUpdatesContains(pid) {
                // If this position is already queued for an update, no need to check anything else
                return
            }

            // If this position is not already queued for an update, we need to check if it needs one
            let position = self._borrowPosition(pid: pid)

            if position.getQueuedDepositsLength() > 0 {
                // This position has deposits that need to be processed, so we need to queue it for an update
                self.state.appendPositionNeedingUpdate(pid)
                return
            }

            let positionHealth = self.positionHealth(pid: pid)

            if positionHealth < position.getMinHealth() || positionHealth > position.getMaxHealth() {
                // This position is outside the configured health bounds, we queue it for an update
                self.state.appendPositionNeedingUpdate(pid)
                return
            }
        }

        /// Returns a position's FlowALPModels.BalanceSheet containing its effective collateral and debt as well as its current health
        /// TODO(jord): in all cases callers already are calling _borrowPosition, more efficient to pass in PositionView?
        access(self) fun _getUpdatedBalanceSheet(pid: UInt64): FlowALPModels.BalanceSheet {
            let position = self._borrowPosition(pid: pid)

            // Get the position's collateral and debt values in terms of the default token.
            var effectiveCollateral: UFix128 = 0.0
            var effectiveDebt: UFix128 = 0.0

            for type in position.getBalanceKeys() {
                let balance = position.getBalance(type)!
                let tokenState = self._borrowUpdatedTokenState(type: type)

                switch balance.direction {
                    case FlowALPModels.BalanceDirection.Credit:
                        let trueBalance = FlowALPMath.scaledBalanceToTrueBalance(
                            balance.scaledBalance,
                            interestIndex: tokenState.getCreditInterestIndex()
                        )

                        let convertedPrice = UFix128(self.config.getPriceOracle().price(ofToken: type)!)
                        let value = convertedPrice * trueBalance

                        let convertedCollateralFactor = UFix128(self.config.getCollateralFactor(tokenType: type))
                        effectiveCollateral = effectiveCollateral + (value * convertedCollateralFactor)

                    case FlowALPModels.BalanceDirection.Debit:
                        let trueBalance = FlowALPMath.scaledBalanceToTrueBalance(
                            balance.scaledBalance,
                            interestIndex: tokenState.getDebitInterestIndex()
                        )

                        let convertedPrice = UFix128(self.config.getPriceOracle().price(ofToken: type)!)
                        let value = convertedPrice * trueBalance

                        let convertedBorrowFactor = UFix128(self.config.getBorrowFactor(tokenType: type))
                        effectiveDebt = effectiveDebt + (value / convertedBorrowFactor)

                }
            }

            return FlowALPModels.BalanceSheet(
                effectiveCollateral: effectiveCollateral,
                effectiveDebt: effectiveDebt
            )
        }

        /// A convenience function that returns a reference to a particular token state, making sure it's up-to-date for
        /// the passage of time. This should always be used when accessing a token state to avoid missing interest
        /// updates (duplicate calls to updateForTimeChange() are a nop within a single block).
        access(self) fun _borrowUpdatedTokenState(type: Type): &{FlowALPModels.TokenState} {
            let state = self.state.borrowTokenState(type)!
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
            if !self.state.hasReserve(tokenType) {
                return
            }

            // Get reference to reserves
            if let reserveRef = self.state.borrowReserve(tokenType) {
                // Collect insurance and get MOET vault
                let oraclePrice = self.config.getPriceOracle().price(ofToken: tokenType)!
                if let collectedMOET <- self._collectInsurance(
                    tokenState: tokenState,
                    reserveVault: reserveRef,
                    oraclePrice: oraclePrice,
                    maxDeviationBps: self.config.getDexOracleDeviationBps()
                ) {
                    let collectedMOETBalance = collectedMOET.balance
                    // Deposit collected MOET into insurance fund
                    self.state.depositToInsuranceFund(from: <-collectedMOET)

                    FlowALPEvents.emitInsuranceFeeCollected(
                        poolUUID: self.uuid,
                        tokenType: tokenType.identifier,
                        insuranceAmount: collectedMOETBalance,
                        collectionTime: tokenState.getLastInsuranceCollectionTime()
                    )
                }
            }
        }

        /// Returns an authorized reference to the requested InternalPosition or `nil` if the position does not exist
        access(self) view fun _borrowPosition(pid: UInt64): &{FlowALPModels.InternalPosition} {
            return &self.positions[pid] as &{FlowALPModels.InternalPosition}?
                ?? panic("Invalid position ID \(pid) - could not find an InternalPosition with the requested ID in the Pool")
        }

        /// Returns a reference to the InternalPosition for the given position ID.
        /// Used by Position resources to directly access their InternalPosition.
        access(FlowALPModels.EPosition) view fun borrowPosition(pid: UInt64): &{FlowALPModels.InternalPosition} {
            return self._borrowPosition(pid: pid)
        }

        /// Build a PositionView for the given position ID.
        access(all) fun buildPositionView(pid: UInt64): FlowALPModels.PositionView {
            let position = self._borrowPosition(pid: pid)
            let snaps: {Type: FlowALPModels.TokenSnapshot} = {}
            let balancesCopy = position.copyBalances()
            for t in position.getBalanceKeys() {
                let tokenState = self._borrowUpdatedTokenState(type: t)
                snaps[t] = FlowALPModels.TokenSnapshot(
                    price: UFix128(self.config.getPriceOracle().price(ofToken: t)!),
                    credit: tokenState.getCreditInterestIndex(),
                    debit: tokenState.getDebitInterestIndex(),
                    risk: FlowALPModels.RiskParamsImplv1(
                        collateralFactor: UFix128(self.config.getCollateralFactor(tokenType: t)),
                        borrowFactor: UFix128(self.config.getBorrowFactor(tokenType: t)),
                    )
                )
            }
            return FlowALPModels.PositionView(
                balances: balancesCopy,
                snapshots: snaps,
                defaultToken: self.state.getDefaultToken(),
                min: position.getMinHealth(),
                max: position.getMaxHealth()
            )
        }

        access(FlowALPModels.EGovernance) fun setPriceOracle(_ newOracle: {DeFiActions.PriceOracle}) {
            self.config.setPriceOracle(newOracle, defaultToken: self.state.getDefaultToken())
            self.state.setPositionsNeedingUpdates(self.positions.keys)

            FlowALPEvents.emitPriceOracleUpdated(
                poolUUID: self.uuid,
                newOracleType: newOracle.getType().identifier
            )
        }

        access(all) fun getDefaultToken(): Type {
            return self.state.getDefaultToken()
        }
        
        /// Returns the deposit capacity and deposit capacity cap for a given token type
        access(all) fun getDepositCapacityInfo(type: Type): {String: UFix64} {
            let tokenState = self._borrowUpdatedTokenState(type: type)
            return {
                "depositCapacity": tokenState.getDepositCapacity(),
                "depositCapacityCap": tokenState.getDepositCapacityCap(),
                "depositRate": tokenState.getDepositRate(),
                "depositLimitFraction": tokenState.getDepositLimitFraction(),
                "lastDepositCapacityUpdate": tokenState.getLastDepositCapacityUpdate()
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
                FlowALPv0.account.storage.type(at: FlowALPv0.PoolStoragePath) == nil:
                    "Storage collision - Pool has already been created & saved to \(FlowALPv0.PoolStoragePath)"
            }
            let pool <- create Pool(
            	defaultToken: defaultToken,
            	priceOracle: priceOracle,
            	dex: dex
            )
            FlowALPv0.account.storage.save(<-pool, to: FlowALPv0.PoolStoragePath)
            let cap = FlowALPv0.account.capabilities.storage.issue<&Pool>(FlowALPv0.PoolStoragePath)
            FlowALPv0.account.capabilities.unpublish(FlowALPv0.PoolPublicPath)
            FlowALPv0.account.capabilities.publish(cap, at: FlowALPv0.PoolPublicPath)
        }
    }

    /// Position
    ///
    /// A Position is a resource representing ownership of value deposited to the protocol.
    /// From a Position, a user can deposit and withdraw funds as well as construct DeFiActions components enabling
    /// value flows in and out of the Position from within the context of DeFiActions stacks.
    /// Unauthorized Position references allow depositing only, and are considered safe to publish.
    /// The FlowALPModels.EPositionAdmin entitlement protects sensitive withdrawal and configuration methods.
    ///
    /// Position resources are held in user accounts and provide access to one position (by pid).
    /// Clients are recommended to use PositionManager to manage access to Positions.
    ///
    access(all) resource Position {

        /// The unique ID of the Position used to track deposits and withdrawals to the Pool
        access(all) let id: UInt64

        /// An authorized Capability to the Pool for which this Position was opened.
        access(self) let pool: Capability<auth(FlowALPModels.EPosition) &Pool>

        init(
            id: UInt64,
            pool: Capability<auth(FlowALPModels.EPosition) &Pool>
        ) {
            pre {
                pool.check():
                    "Invalid Pool Capability provided - cannot construct Position"
            }
            self.id = id
            self.pool = pool
        }

        /// Returns the balances (both positive and negative) for all tokens in this position.
        access(all) fun getBalances(): [FlowALPModels.PositionBalance] {
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
            let pos = pool.borrowPosition(pid: self.id)
            return FlowALPMath.toUFix64Round(pos.getTargetHealth())
        }

        /// Sets the target health of the Position
        access(FlowALPModels.EPositionAdmin) fun setTargetHealth(targetHealth: UFix64) {
            let pool = self.pool.borrow()!
            let pos = pool.borrowPosition(pid: self.id)
            pos.setTargetHealth(UFix128(targetHealth))
        }

        /// Returns the minimum health of the Position
        access(all) fun getMinHealth(): UFix64 {
            let pool = self.pool.borrow()!
            let pos = pool.borrowPosition(pid: self.id)
            return FlowALPMath.toUFix64Round(pos.getMinHealth())
        }

        /// Sets the minimum health of the Position
        access(FlowALPModels.EPositionAdmin) fun setMinHealth(minHealth: UFix64) {
            let pool = self.pool.borrow()!
            let pos = pool.borrowPosition(pid: self.id)
            pos.setMinHealth(UFix128(minHealth))
        }

        /// Returns the maximum health of the Position
        access(all) fun getMaxHealth(): UFix64 {
            let pool = self.pool.borrow()!
            let pos = pool.borrowPosition(pid: self.id)
            return FlowALPMath.toUFix64Round(pos.getMaxHealth())
        }

        /// Sets the maximum health of the position
        access(FlowALPModels.EPositionAdmin) fun setMaxHealth(maxHealth: UFix64) {
            let pool = self.pool.borrow()!
            let pos = pool.borrowPosition(pid: self.id)
            pos.setMaxHealth(UFix128(maxHealth))
        }

        /// Returns the maximum amount of the given token type that could be deposited into this position
        access(all) fun getDepositCapacity(type: Type): UFix64 {
            // There's no limit on deposits from the position's perspective
            return UFix64.max
        }

        /// Deposits funds to the Position without immediately pushing to the drawDownSink if the deposit puts the Position above its maximum health.
        /// NOTE: Anyone is allowed to deposit to any position.
        access(all) fun deposit(from: @{FungibleToken.Vault}) {
            self.depositAndPush(
                from: <-from,
                pushToDrawDownSink: false
            )
        }

        /// Deposits funds to the Position enabling the caller to configure whether excess value
        /// should be pushed to the drawDownSink if the deposit puts the Position above its maximum health
        /// NOTE: Anyone is allowed to deposit to any position.
        access(all) fun depositAndPush(
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
        /// if the withdrawal puts the Position below its minimum health
        access(FungibleToken.Withdraw) fun withdraw(type: Type, amount: UFix64): @{FungibleToken.Vault} {
            return <- self.withdrawAndPull(
                type: type,
                amount: amount,
                pullFromTopUpSource: false
            )
        }

        /// Withdraws funds from the Position enabling the caller to configure whether insufficient value
        /// should be pulled from the topUpSource if the withdrawal puts the Position below its minimum health
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
            // Create source with pullFromTopUpSource = false
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
        access(FlowALPModels.EPositionAdmin) fun provideSink(sink: {DeFiActions.Sink}?) {
            let pool = self.pool.borrow()!
            pool.lockPosition(self.id)
            let pos = pool.borrowPosition(pid: self.id)
            pos.setDrawDownSink(sink)
            pool.unlockPosition(self.id)
        }

        /// Provides a source to the Position that will have tokens proactively pulled from it
        /// when the position has insufficient collateral.
        /// If the source can cover the position's debt, the position will not be liquidated.
        ///
        /// Each position can have only one source, and the source must accept the default token type
        /// configured for the pool. Providing a new source will replace the existing source.
        ///
        /// Pass nil to configure the position to not pull tokens.
        access(FlowALPModels.EPositionAdmin) fun provideSource(source: {DeFiActions.Source}?) {
            let pool = self.pool.borrow()!
            pool.lockPosition(self.id)
            let pos = pool.borrowPosition(pid: self.id)
            pos.setTopUpSource(source)
            pool.unlockPosition(self.id)
        }

        /// Rebalances the position to the target health value, if the position is under- or over-collateralized,
        /// as defined by the position-specific min/max health thresholds.
        /// If force=true, the position will be rebalanced regardless of its current health.
        ///
        /// When rebalancing, funds are withdrawn from the position's topUpSource or deposited to its drawDownSink.
        /// Rebalancing is done on a best effort basis (even when force=true). If the position has no sink/source,
        /// of either cannot accept/provide sufficient funds for rebalancing, the rebalance will still occur but will
        /// not cause the position to reach its target health.
        access(FlowALPModels.EPosition | FlowALPModels.ERebalance) fun rebalance(force: Bool) {
            let pool = self.pool.borrow()!
            pool.rebalancePosition(pid: self.id, force: force)
        }
    }

    /// PositionManager
    ///
    /// A collection resource that manages multiple Position resources for an account.
    /// This allows users to have multiple positions while using a single, constant storage path.
    ///
    access(all) resource PositionManager {

        /// Dictionary storing all positions owned by this manager, keyed by position ID
        access(self) let positions: @{UInt64: Position}

        init() {
            self.positions <- {}
        }

        /// Adds a new position to the manager.
        access(FlowALPModels.EPositionAdmin) fun addPosition(position: @Position) {
            let pid = position.id
            let old <- self.positions[pid] <- position
            if old != nil {
                panic("Cannot add position with same pid (\(pid)) as existing position: must explicitly remove existing position first")
            }
            destroy old
        }

        /// Removes and returns a position from the manager.
        access(FlowALPModels.EPositionAdmin) fun removePosition(pid: UInt64): @Position {
            if let position <- self.positions.remove(key: pid) {
                return <-position
            }
            panic("Position with pid=\(pid) not found in PositionManager")
        }

        /// Internal method that returns a reference to a position authorized with all entitlements.
        /// Callers who wish to provide a partially authorized reference can downcast the result as needed.
        access(FlowALPModels.EPositionAdmin) fun borrowAuthorizedPosition(pid: UInt64): auth(FungibleToken.Withdraw, FlowALPModels.EPositionAdmin) &Position {
            return (&self.positions[pid] as auth(FungibleToken.Withdraw, FlowALPModels.EPositionAdmin) &Position?)
                ?? panic("Position with pid=\(pid) not found in PositionManager")
        }

        /// Returns a public reference to a position with no entitlements.
        access(all) fun borrowPosition(pid: UInt64): &Position {
            return (&self.positions[pid] as &Position?)
                ?? panic("Position with pid=\(pid) not found in PositionManager")
        }

        /// Returns the IDs of all positions in this manager
        access(all) fun getPositionIDs(): [UInt64] {
            return self.positions.keys
        }
    }

    /// Creates and returns a new PositionManager resource
    access(all) fun createPositionManager(): @PositionManager {
        return <- create PositionManager()
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
        access(self) let pool: Capability<auth(FlowALPModels.EPosition) &Pool>

        /// The ID of the position in the Pool
        access(self) let positionID: UInt64

        /// The Type of Vault this Sink accepts
        access(self) let type: Type

        /// Whether deposits through this Sink to the Position should push available value to the Position's
        /// drawDownSink
        access(self) let pushToDrawDownSink: Bool

        init(
            id: UInt64,
            pool: Capability<auth(FlowALPModels.EPosition) &Pool>,
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
        access(self) let pool: Capability<auth(FlowALPModels.EPosition) &Pool>

        /// The ID of the position in the Pool
        access(self) let positionID: UInt64

        /// The Type of Vault this Sink provides
        access(self) let type: Type

        /// Whether withdrawals through this Sink from the Position should pull value from the Position's topUpSource
        /// in the event the withdrawal puts the position under its target health
        access(self) let pullFromTopUpSource: Bool

        init(
            id: UInt64,
            pool: Capability<auth(FlowALPModels.EPosition) &Pool>,
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

    /* --- PUBLIC METHODS ---- */

    // TODO(now): remove delegate methods

    /// Checks that the DEX price does not deviate from the oracle price by more than the given threshold.
    /// Delegates to FlowALPMath.dexOraclePriceDeviationInRange.
    access(all) view fun dexOraclePriceDeviationInRange(dexPrice: UFix64, oraclePrice: UFix64, maxDeviationBps: UInt16): Bool {
        return FlowALPMath.dexOraclePriceDeviationInRange(dexPrice: dexPrice, oraclePrice: oraclePrice, maxDeviationBps: maxDeviationBps)
    }

    /// Converts a yearly interest rate to a per-second multiplication factor.
    /// Delegates to FlowALPMath.perSecondInterestRate.
    access(all) view fun perSecondInterestRate(yearlyRate: UFix128): UFix128 {
        return FlowALPMath.perSecondInterestRate(yearlyRate: yearlyRate)
    }

    /// Returns the compounded interest index reflecting the passage of time.
    /// Delegates to FlowALPMath.compoundInterestIndex.
    access(all) view fun compoundInterestIndex(
        oldIndex: UFix128,
        perSecondRate: UFix128,
        elapsedSeconds: UFix64
    ): UFix128 {
        return FlowALPMath.compoundInterestIndex(oldIndex: oldIndex, perSecondRate: perSecondRate, elapsedSeconds: elapsedSeconds)
    }

    /* --- INTERNAL METHODS --- */

    /// Returns a reference to the contract account's MOET Minter resource
    access(self) view fun _borrowMOETMinter(): &MOET.Minter {
        return self.account.storage.borrow<&MOET.Minter>(from: MOET.AdminStoragePath)
            ?? panic("Could not borrow reference to internal MOET Minter resource")
    }

    init() {
        self.PoolStoragePath = StoragePath(identifier: "flowALPv0Pool_\(self.account.address)")!
        self.PoolFactoryPath = StoragePath(identifier: "flowALPv0PoolFactory_\(self.account.address)")!
        self.PoolPublicPath = PublicPath(identifier: "flowALPv0Pool_\(self.account.address)")!
        self.PoolCapStoragePath = StoragePath(identifier: "flowALPv0PoolCap_\(self.account.address)")!

        self.PositionStoragePath = StoragePath(identifier: "flowALPv0Position_\(self.account.address)")!
        self.PositionPublicPath = PublicPath(identifier: "flowALPv0Position_\(self.account.address)")!

        // save PoolFactory in storage
        self.account.storage.save(
            <-create PoolFactory(),
            to: self.PoolFactoryPath
        )
        let factory = self.account.storage.borrow<&PoolFactory>(from: self.PoolFactoryPath)!
    }
}
