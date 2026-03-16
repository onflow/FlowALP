import "FlowALPMath"
import "FlowALPModels"

access(all) contract FlowALPHealth {

    /// Computes adjusted effective collateral and debt after a hypothetical withdrawal.
    ///
    /// This function determines how a withdrawal would affect the position's balance sheet,
    /// accounting for whether the position holds a credit (collateral) or debit (debt) balance
    /// in the withdrawn token. If the position has collateral in the token, the withdrawal may
    /// either draw down collateral, or exhaust it entirely and create new debt.
    ///
    /// @param balanceSheet: The position's current effective collateral and debt (with per-token maps)
    /// @param withdrawBalance: The position's existing balance for the withdrawn token, if any
    /// @param withdrawType: The type of token being withdrawn
    /// @param withdrawAmount: The amount of tokens to withdraw
    /// @param withdrawPrice: The oracle price of the withdrawn token
    /// @param withdrawBorrowFactor: The borrow factor applied to debt in the withdrawn token
    /// @param withdrawCollateralFactor: The collateral factor applied to collateral in the withdrawn token
    /// @param withdrawCreditInterestIndex: The credit interest index for the withdrawn token
    /// @return A new BalanceSheet reflecting the effective collateral and debt after the withdrawal
    access(account) fun computeAdjustedBalancesAfterWithdrawal(
        balanceSheet: FlowALPModels.BalanceSheet,
        withdrawBalance: FlowALPModels.InternalBalance?,
        withdrawType: Type,
        withdrawAmount: UFix64,
        withdrawPrice: UFix128,
        withdrawBorrowFactor: UFix128,
        withdrawCollateralFactor: UFix128,
        withdrawCreditInterestIndex: UFix128
    ): FlowALPModels.BalanceSheet {
        if withdrawAmount == 0.0 {
            return balanceSheet
        }

        let withdrawAmountU = UFix128(withdrawAmount)
        let balance = withdrawBalance
        let direction = balance?.direction ?? FlowALPModels.BalanceDirection.Debit
        let scaledBalance = balance?.scaledBalance ?? 0.0

        // Compute the new per-token effective collateral and debt after the withdrawal.
        var newEffectiveCollateral: UFix128? = balanceSheet.effectiveCollateralByToken[withdrawType]
        var newEffectiveDebt: UFix128? = balanceSheet.effectiveDebtByToken[withdrawType]

        switch direction {
            case FlowALPModels.BalanceDirection.Debit:
                // No collateral for the withdrawn token — the withdrawal creates additional debt.
                let additionalDebt = (withdrawAmountU * withdrawPrice) / withdrawBorrowFactor
                newEffectiveDebt = (newEffectiveDebt ?? 0.0) + additionalDebt

            case FlowALPModels.BalanceDirection.Credit:
                // The user has a collateral position in the given token.
                let trueCollateral = FlowALPMath.scaledBalanceToTrueBalance(
                    scaledBalance,
                    interestIndex: withdrawCreditInterestIndex
                )
                if trueCollateral >= withdrawAmountU {
                    // Withdrawal draws down collateral without creating debt.
                    let collateralDecrease = (withdrawAmountU * withdrawPrice) * withdrawCollateralFactor
                    newEffectiveCollateral = (newEffectiveCollateral ?? 0.0) - collateralDecrease
                } else {
                    // Withdrawal wipes out all collateral and creates some debt.
                    let existingCollateral = (trueCollateral * withdrawPrice) * withdrawCollateralFactor
                    newEffectiveCollateral = (newEffectiveCollateral ?? 0.0) - existingCollateral
                    let additionalDebt = ((withdrawAmountU - trueCollateral) * withdrawPrice) / withdrawBorrowFactor
                    newEffectiveDebt = (newEffectiveDebt ?? 0.0) + additionalDebt
                }
        }

        // Clean up zero/nil entries
        if newEffectiveCollateral == 0.0 { newEffectiveCollateral = nil }
        if newEffectiveDebt == 0.0 { newEffectiveDebt = nil }

        return balanceSheet.withUpdatedContributions(
            tokenType: withdrawType,
            effectiveCollateral: newEffectiveCollateral,
            effectiveDebt: newEffectiveDebt
        )
    }

    /// Computes the amount of a given token that must be deposited to bring a position to a target health.
    ///
    /// This function handles the case where the deposit token may have an existing debit (debt) balance.
    /// If so, the deposit first pays down debt before accumulating as collateral. The computation
    /// determines the minimum deposit required to reach the target health, accounting for both
    /// debt repayment and collateral accumulation as needed.
    ///
    /// @param depositBalance: The position's existing balance for the deposit token, if any
    /// @param depositDebitInterestIndex: The debit interest index for the deposit token
    /// @param depositPrice: The oracle price of the deposit token
    /// @param depositBorrowFactor: The borrow factor applied to debt in the deposit token
    /// @param depositCollateralFactor: The collateral factor applied to collateral in the deposit token
    /// @param adjusted: The position's current health statement (post any prior withdrawal)
    /// @param targetHealth: The target health ratio to achieve
    /// @param isDebugLogging: Whether to emit debug log messages
    /// @return The amount of tokens (in UFix64) required to reach the target health
    access(account) fun computeRequiredDepositForHealth(
        depositBalance: FlowALPModels.InternalBalance?,
        depositDebitInterestIndex: UFix128,
        depositPrice: UFix128,
        depositBorrowFactor: UFix128,
        depositCollateralFactor: UFix128,
        adjusted: FlowALPModels.HealthStatement,
        targetHealth: UFix128,
        isDebugLogging: Bool
    ): UFix64 {
        let effectiveCollateralAfterWithdrawal = adjusted.effectiveCollateral
        var effectiveDebtAfterWithdrawal = adjusted.effectiveDebt
        if isDebugLogging {
            log("    [CONTRACT] effectiveCollateralAfterWithdrawal: \(effectiveCollateralAfterWithdrawal)")
            log("    [CONTRACT] effectiveDebtAfterWithdrawal: \(effectiveDebtAfterWithdrawal)")
        }

        var healthAfterWithdrawal = adjusted.health
        if isDebugLogging {
            log("    [CONTRACT] healthAfterWithdrawal: \(healthAfterWithdrawal)")
        }

        if healthAfterWithdrawal >= targetHealth {
            return 0.0
        }

        // For situations where the required deposit will BOTH pay off debt and accumulate collateral, we keep
        // track of the number of tokens that went towards paying off debt.
        var debtTokenCount: UFix128 = 0.0
        let maybeBalance = depositBalance
        if maybeBalance?.direction == FlowALPModels.BalanceDirection.Debit {
            let debtBalance = maybeBalance!.scaledBalance
            let trueDebtTokenCount = FlowALPMath.scaledBalanceToTrueBalance(
                debtBalance,
                interestIndex: depositDebitInterestIndex
            )
            let debtEffectiveValue = (depositPrice * trueDebtTokenCount) / depositBorrowFactor

            var effectiveDebtAfterPayment: UFix128 = 0.0
            if debtEffectiveValue <= effectiveDebtAfterWithdrawal {
                effectiveDebtAfterPayment = effectiveDebtAfterWithdrawal - debtEffectiveValue
            }

            let potentialHealth = FlowALPMath.healthComputation(
                effectiveCollateral: effectiveCollateralAfterWithdrawal,
                effectiveDebt: effectiveDebtAfterPayment
            )

            if potentialHealth >= targetHealth {
                let requiredEffectiveDebt = effectiveDebtAfterWithdrawal
                    - (effectiveCollateralAfterWithdrawal / targetHealth)
                let paybackAmount = (requiredEffectiveDebt * depositBorrowFactor) / depositPrice
                if isDebugLogging {
                    log("    [CONTRACT] paybackAmount: \(paybackAmount)")
                }
                return FlowALPMath.toUFix64RoundUp(paybackAmount)
            } else {
                debtTokenCount = trueDebtTokenCount
                if debtEffectiveValue <= effectiveDebtAfterWithdrawal {
                    effectiveDebtAfterWithdrawal = effectiveDebtAfterWithdrawal - debtEffectiveValue
                } else {
                    effectiveDebtAfterWithdrawal = 0.0
                }
                healthAfterWithdrawal = potentialHealth
            }
        }

        let healthChangeU = targetHealth - healthAfterWithdrawal
        let requiredEffectiveCollateral = (healthChangeU * effectiveDebtAfterWithdrawal) / depositCollateralFactor

        let collateralTokenCount = requiredEffectiveCollateral / depositPrice
        if isDebugLogging {
            log("    [CONTRACT] requiredEffectiveCollateral: \(requiredEffectiveCollateral)")
            log("    [CONTRACT] collateralTokenCount: \(collateralTokenCount)")
            log("    [CONTRACT] debtTokenCount: \(debtTokenCount)")
            log("    [CONTRACT] collateralTokenCount + debtTokenCount: \(collateralTokenCount) + \(debtTokenCount) = \(collateralTokenCount + debtTokenCount)")
        }

        return FlowALPMath.toUFix64Round(collateralTokenCount + debtTokenCount)
    }

    /// Computes adjusted effective collateral and debt after a hypothetical deposit.
    ///
    /// This function determines how a deposit would affect the position's balance sheet,
    /// accounting for whether the position holds a credit (collateral) or debit (debt) balance
    /// in the deposited token. If the position has debt in the token, the deposit first pays
    /// down debt before accumulating as collateral.
    ///
    /// @param balanceSheet: The position's current effective collateral and debt (with per-token maps)
    /// @param depositBalance: The position's existing balance for the deposited token, if any
    /// @param depositType: The type of token being deposited
    /// @param depositAmount: The amount of tokens to deposit
    /// @param depositPrice: The oracle price of the deposited token
    /// @param depositBorrowFactor: The borrow factor applied to debt in the deposited token
    /// @param depositCollateralFactor: The collateral factor applied to collateral in the deposited token
    /// @param depositDebitInterestIndex: The debit interest index for the deposited token
    /// @return A new BalanceSheet reflecting the effective collateral and debt after the deposit
    access(account) fun computeAdjustedBalancesAfterDeposit(
        balanceSheet: FlowALPModels.BalanceSheet,
        depositBalance: FlowALPModels.InternalBalance?,
        depositType: Type,
        depositAmount: UFix64,
        depositPrice: UFix128,
        depositBorrowFactor: UFix128,
        depositCollateralFactor: UFix128,
        depositDebitInterestIndex: UFix128,
        isDebugLogging: Bool
    ): FlowALPModels.BalanceSheet {
        if depositAmount == 0.0 {
            return balanceSheet
        }

        let depositAmountU = UFix128(depositAmount)
        let balance = depositBalance
        let direction = balance?.direction ?? FlowALPModels.BalanceDirection.Credit
        let scaledBalance = balance?.scaledBalance ?? 0.0

        // Compute the new per-token effective collateral and debt after the deposit.
        var newEffectiveCollateral: UFix128? = balanceSheet.effectiveCollateralByToken[depositType]
        var newEffectiveDebt: UFix128? = balanceSheet.effectiveDebtByToken[depositType]

        switch direction {
            case FlowALPModels.BalanceDirection.Credit:
                // No debt for the deposit token — the deposit creates additional collateral.
                let additionalCollateral = (depositAmountU * depositPrice) * depositCollateralFactor
                newEffectiveCollateral = (newEffectiveCollateral ?? 0.0) + additionalCollateral

            case FlowALPModels.BalanceDirection.Debit:
                // The user has a debt position in the given token.
                let trueDebt = FlowALPMath.scaledBalanceToTrueBalance(
                    scaledBalance,
                    interestIndex: depositDebitInterestIndex
                )
                if isDebugLogging {
                    log("    [CONTRACT] trueDebt: \(trueDebt)")
                }

                if trueDebt >= depositAmountU {
                    // Deposit pays down some debt without creating collateral.
                    let debtDecrease = (depositAmountU * depositPrice) / depositBorrowFactor
                    newEffectiveDebt = (newEffectiveDebt ?? 0.0) - debtDecrease
                } else {
                    // Deposit wipes out all debt and creates some collateral.
                    let existingDebt = (trueDebt * depositPrice) / depositBorrowFactor
                    newEffectiveDebt = (newEffectiveDebt ?? 0.0) - existingDebt
                    let additionalCollateral = ((depositAmountU - trueDebt) * depositPrice) * depositCollateralFactor
                    newEffectiveCollateral = (newEffectiveCollateral ?? 0.0) + additionalCollateral
                }
        }
        if isDebugLogging {
            log("    [CONTRACT] effectiveCollateralAfterDeposit: \(newEffectiveCollateral ?? 0.0)")
            log("    [CONTRACT] effectiveDebtAfterDeposit: \(newEffectiveDebt ?? 0.0)")
        }

        // Clean up zero/nil entries
        if newEffectiveCollateral == 0.0 { newEffectiveCollateral = nil }
        if newEffectiveDebt == 0.0 { newEffectiveDebt = nil }

        return balanceSheet.withUpdatedContributions(
            tokenType: depositType,
            effectiveCollateral: newEffectiveCollateral,
            effectiveDebt: newEffectiveDebt
        )
    }

    /// Computes the maximum amount of a given token that can be withdrawn while maintaining a target health.
    ///
    /// @param withdrawBalance: The position's existing balance for the withdrawn token, if any
    /// @param withdrawCreditInterestIndex: The credit interest index for the withdrawn token
    /// @param withdrawPrice: The oracle price of the withdrawn token
    /// @param withdrawCollateralFactor: The collateral factor applied to collateral in the withdrawn token
    /// @param withdrawBorrowFactor: The borrow factor applied to debt in the withdrawn token
    /// @param adjusted: The position's current health statement (post any prior deposit)
    /// @param targetHealth: The minimum health ratio to maintain
    /// @param isDebugLogging: Whether to emit debug log messages
    /// @return The maximum amount of tokens (in UFix64) that can be withdrawn
    access(account) fun computeAvailableWithdrawal(
        withdrawBalance: FlowALPModels.InternalBalance?,
        withdrawCreditInterestIndex: UFix128,
        withdrawPrice: UFix128,
        withdrawCollateralFactor: UFix128,
        withdrawBorrowFactor: UFix128,
        adjusted: FlowALPModels.HealthStatement,
        targetHealth: UFix128,
        isDebugLogging: Bool
    ): UFix64 {
        var effectiveCollateralAfterDeposit = adjusted.effectiveCollateral
        let effectiveDebtAfterDeposit = adjusted.effectiveDebt

        let healthAfterDeposit = adjusted.health
        if isDebugLogging {
            log("    [CONTRACT] healthAfterDeposit: \(healthAfterDeposit)")
        }

        if healthAfterDeposit <= targetHealth {
            return 0.0
        }

        var collateralTokenCount: UFix128 = 0.0

        let maybeBalance = withdrawBalance
        if maybeBalance?.direction == FlowALPModels.BalanceDirection.Credit {
            let creditBalance = maybeBalance!.scaledBalance
            let trueCredit = FlowALPMath.scaledBalanceToTrueBalance(
                creditBalance,
                interestIndex: withdrawCreditInterestIndex
            )
            let collateralEffectiveValue = (withdrawPrice * trueCredit) * withdrawCollateralFactor

            let potentialHealth = FlowALPMath.healthComputation(
                effectiveCollateral: effectiveCollateralAfterDeposit - collateralEffectiveValue,
                effectiveDebt: effectiveDebtAfterDeposit
            )

            if potentialHealth <= targetHealth {
                let availableEffectiveValue = effectiveCollateralAfterDeposit - (targetHealth * effectiveDebtAfterDeposit)
                if isDebugLogging {
                    log("    [CONTRACT] availableEffectiveValue: \(availableEffectiveValue)")
                }

                let availableTokenCount = (availableEffectiveValue / withdrawCollateralFactor) / withdrawPrice
                if isDebugLogging {
                    log("    [CONTRACT] availableTokenCount: \(availableTokenCount)")
                }

                return FlowALPMath.toUFix64RoundDown(availableTokenCount)
            } else {
                collateralTokenCount = trueCredit
                effectiveCollateralAfterDeposit = effectiveCollateralAfterDeposit - collateralEffectiveValue
                if isDebugLogging {
                    log("    [CONTRACT] collateralTokenCount: \(collateralTokenCount)")
                    log("    [CONTRACT] effectiveCollateralAfterDeposit: \(effectiveCollateralAfterDeposit)")
                }

                let availableDebtIncrease = (effectiveCollateralAfterDeposit / targetHealth) - effectiveDebtAfterDeposit
                let availableTokens = (availableDebtIncrease * withdrawBorrowFactor) / withdrawPrice
                if isDebugLogging {
                    log("    [CONTRACT] availableDebtIncrease: \(availableDebtIncrease)")
                    log("    [CONTRACT] availableTokens: \(availableTokens)")
                    log("    [CONTRACT] availableTokens + collateralTokenCount: \(availableTokens + collateralTokenCount)")
                }

                return FlowALPMath.toUFix64RoundDown(availableTokens + collateralTokenCount)
            }
        }

        let availableDebtIncrease = (effectiveCollateralAfterDeposit / targetHealth) - effectiveDebtAfterDeposit
        let availableTokens = (availableDebtIncrease * withdrawBorrowFactor) / withdrawPrice
        if isDebugLogging {
            log("    [CONTRACT] availableDebtIncrease: \(availableDebtIncrease)")
            log("    [CONTRACT] availableTokens: \(availableTokens)")
            log("    [CONTRACT] availableTokens + collateralTokenCount: \(availableTokens + collateralTokenCount)")
        }

        return FlowALPMath.toUFix64RoundDown(availableTokens + collateralTokenCount)
    }
}
