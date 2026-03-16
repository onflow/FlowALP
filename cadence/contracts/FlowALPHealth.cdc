import "FlowALPMath"
import "FlowALPModels"

access(all) contract FlowALPHealth {

    /// Computes adjusted effective collateral and debt after a hypothetical withdrawal.
    ///
    /// Uses a "remove old contribution, add new contribution" approach:
    /// 1. Remove the current per-token effective collateral/debt entry
    /// 2. Compute the new true balance after the withdrawal
    /// 3. Compute the new effective contribution from the post-withdrawal balance
    /// 4. Return a new BalanceSheet with the updated per-token entry
    ///
    /// @param balanceSheet: The position's current effective collateral and debt (with per-token maps)
    /// @param withdrawBalance: The position's existing balance for the withdrawn token, if any
    /// @param withdrawType: The type of token being withdrawn
    /// @param withdrawAmount: The amount of tokens to withdraw
    /// @param tokenSnapshot: Snapshot of the withdrawn token's price, interest indices, and risk params
    /// @return A new BalanceSheet reflecting the effective collateral and debt after the withdrawal
    access(account) fun computeAdjustedBalancesAfterWithdrawal(
        balanceSheet: FlowALPModels.BalanceSheet,
        withdrawBalance: FlowALPModels.InternalBalance?,
        withdrawType: Type,
        withdrawAmount: UFix64,
        tokenSnapshot: FlowALPModels.TokenSnapshot
    ): FlowALPModels.BalanceSheet {
        if withdrawAmount == 0.0 {
            return balanceSheet
        }

        let withdrawAmountU = UFix128(withdrawAmount)

        // Compute the post-withdrawal true balance and direction.
        let after = self.trueBalanceAfterWithdrawal(
            balance: withdrawBalance,
            withdrawAmount: withdrawAmountU,
            tokenSnapshot: tokenSnapshot
        )

        // Compute new per-token effective values from the post-withdrawal true balance.
        var newEffectiveCollateral: UFix128? = nil
        var newEffectiveDebt: UFix128? = nil
        if after.quantity > 0.0 {
            switch after.direction {
                case FlowALPModels.BalanceDirection.Credit:
                    newEffectiveCollateral = tokenSnapshot.effectiveCollateral(creditBalance: after.quantity)
                case FlowALPModels.BalanceDirection.Debit:
                    newEffectiveDebt = tokenSnapshot.effectiveDebt(debitBalance: after.quantity)
            }
        }

        return balanceSheet.withUpdatedContributions(
            tokenType: withdrawType,
            effectiveCollateral: newEffectiveCollateral,
            effectiveDebt: newEffectiveDebt
        )
    }

    /// Computes the true balance (direction + amount) after a withdrawal.
    ///
    /// Starting from the current balance (credit or debit), subtracts the withdrawal amount.
    /// If the position has credit, the withdrawal draws it down and may flip into debt.
    /// If the position has debt (or no balance), the withdrawal increases debt.
    access(self) fun trueBalanceAfterWithdrawal(
        balance: FlowALPModels.InternalBalance?,
        withdrawAmount: UFix128,
        tokenSnapshot: FlowALPModels.TokenSnapshot
    ): FlowALPModels.SignedQuantity {
        let direction = balance?.direction ?? FlowALPModels.BalanceDirection.Debit
        let scaledBalance = balance?.scaledBalance ?? 0.0

        switch direction {
            case FlowALPModels.BalanceDirection.Debit:
                // Currently in debt — withdrawal adds more debt.
                let trueDebt = FlowALPMath.scaledBalanceToTrueBalance(
                    scaledBalance, interestIndex: tokenSnapshot.debitIndex
                )
                return FlowALPModels.SignedQuantity(
                    direction: FlowALPModels.BalanceDirection.Debit,
                    quantity: trueDebt + withdrawAmount
                )

            case FlowALPModels.BalanceDirection.Credit:
                // Currently has credit — withdrawal draws it down, possibly flipping to debt.
                let trueCredit = FlowALPMath.scaledBalanceToTrueBalance(
                    scaledBalance, interestIndex: tokenSnapshot.creditIndex
                )
                if trueCredit >= withdrawAmount {
                    return FlowALPModels.SignedQuantity(
                        direction: FlowALPModels.BalanceDirection.Credit,
                        quantity: trueCredit - withdrawAmount
                    )
                } else {
                    return FlowALPModels.SignedQuantity(
                        direction: FlowALPModels.BalanceDirection.Debit,
                        quantity: withdrawAmount - trueCredit
                    )
                }
        }
        panic("unreachable")
    }

    /// Computes the amount of a given token that must be deposited to bring a position to a target health.
    ///
    // TODO(jord): ~100-line function - consider refactoring
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
        // TODO: apply the same logic as below to the early return blocks above
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
    /// Uses a "remove old contribution, add new contribution" approach:
    /// 1. Remove the current per-token effective collateral/debt entry
    /// 2. Compute the new true balance after the deposit
    /// 3. Compute the new effective contribution from the post-deposit balance
    /// 4. Return a new BalanceSheet with the updated per-token entry
    ///
    /// @param balanceSheet: The position's current effective collateral and debt (with per-token maps)
    /// @param depositBalance: The position's existing balance for the deposited token, if any
    /// @param depositType: The type of token being deposited
    /// @param depositAmount: The amount of tokens to deposit
    /// @param tokenSnapshot: Snapshot of the deposited token's price, interest indices, and risk params
    /// @return A new BalanceSheet reflecting the effective collateral and debt after the deposit
    access(account) fun computeAdjustedBalancesAfterDeposit(
        balanceSheet: FlowALPModels.BalanceSheet,
        depositBalance: FlowALPModels.InternalBalance?,
        depositType: Type,
        depositAmount: UFix64,
        tokenSnapshot: FlowALPModels.TokenSnapshot
    ): FlowALPModels.BalanceSheet {
        if depositAmount == 0.0 {
            return balanceSheet
        }

        let depositAmountU = UFix128(depositAmount)

        // Compute the post-deposit true balance and direction.
        let after = self.trueBalanceAfterDeposit(
            balance: depositBalance,
            depositAmount: depositAmountU,
            tokenSnapshot: tokenSnapshot
        )

        // Compute new per-token effective values from the post-deposit true balance.
        var newEffectiveCollateral: UFix128? = nil
        var newEffectiveDebt: UFix128? = nil
        if after.quantity > 0.0 {
            switch after.direction {
                case FlowALPModels.BalanceDirection.Credit:
                    newEffectiveCollateral = tokenSnapshot.effectiveCollateral(creditBalance: after.quantity)
                case FlowALPModels.BalanceDirection.Debit:
                    newEffectiveDebt = tokenSnapshot.effectiveDebt(debitBalance: after.quantity)
            }
        }

        return balanceSheet.withUpdatedContributions(
            tokenType: depositType,
            effectiveCollateral: newEffectiveCollateral,
            effectiveDebt: newEffectiveDebt
        )
    }

    /// Computes the true balance (direction + amount) after a deposit.
    ///
    /// Starting from the current balance (credit or debit), adds the deposit amount.
    /// If the position has debt, the deposit pays it down and may flip into credit.
    /// If the position has credit (or no balance), the deposit increases credit.
    access(self) fun trueBalanceAfterDeposit(
        balance: FlowALPModels.InternalBalance?,
        depositAmount: UFix128,
        tokenSnapshot: FlowALPModels.TokenSnapshot
    ): FlowALPModels.SignedQuantity {
        let direction = balance?.direction ?? FlowALPModels.BalanceDirection.Credit
        let scaledBalance = balance?.scaledBalance ?? 0.0

        switch direction {
            case FlowALPModels.BalanceDirection.Credit:
                // Currently has credit — deposit adds more credit.
                let trueCredit = FlowALPMath.scaledBalanceToTrueBalance(
                    scaledBalance, interestIndex: tokenSnapshot.creditIndex
                )
                return FlowALPModels.SignedQuantity(
                    direction: FlowALPModels.BalanceDirection.Credit,
                    quantity: trueCredit + depositAmount
                )

            case FlowALPModels.BalanceDirection.Debit:
                // Currently in debt — deposit pays it down, possibly flipping to credit.
                let trueDebt = FlowALPMath.scaledBalanceToTrueBalance(
                    scaledBalance, interestIndex: tokenSnapshot.debitIndex
                )
                if trueDebt >= depositAmount {
                    return FlowALPModels.SignedQuantity(
                        direction: FlowALPModels.BalanceDirection.Debit,
                        quantity: trueDebt - depositAmount
                    )
                } else {
                    return FlowALPModels.SignedQuantity(
                        direction: FlowALPModels.BalanceDirection.Credit,
                        quantity: depositAmount - trueDebt
                    )
                }
        }
        panic("unreachable")
    }

    // TODO(jord): ~100-line function - consider refactoring
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
