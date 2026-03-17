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

        let effectiveBalance = tokenSnapshot.effectiveBalance(balance: after)
        return balanceSheet.withReplacedTokenBalance(
            tokenType: withdrawType,
            effectiveBalance: effectiveBalance
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
    ): FlowALPModels.Balance {
        let direction = balance?.scaledBalance?.direction ?? FlowALPModels.BalanceDirection.Debit
        let scaledBalance = balance?.scaledBalance?.quantity ?? 0.0

        switch direction {
            case FlowALPModels.BalanceDirection.Debit:
                // Currently in debt — withdrawal adds more debt.
                let trueDebt = FlowALPMath.scaledBalanceToTrueBalance(
                    scaledBalance, interestIndex: tokenSnapshot.debitIndex
                )
                return FlowALPModels.Balance(
                    direction: FlowALPModels.BalanceDirection.Debit,
                    quantity: trueDebt + withdrawAmount
                )

            case FlowALPModels.BalanceDirection.Credit:
                // Currently has credit — withdrawal draws it down, possibly flipping to debt.
                let trueCredit = FlowALPMath.scaledBalanceToTrueBalance(
                    scaledBalance, interestIndex: tokenSnapshot.creditIndex
                )
                if trueCredit >= withdrawAmount {
                    return FlowALPModels.Balance(
                        direction: FlowALPModels.BalanceDirection.Credit,
                        quantity: trueCredit - withdrawAmount
                    )
                } else {
                    return FlowALPModels.Balance(
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

        // We now have new effective collateral and debt values that reflect the proposed withdrawal (if any!)
        // Now we can figure out how many of the given token would need to be deposited to bring the position
        // to the target health value.
        var healthAfterWithdrawal = adjusted.health
        if isDebugLogging {
            log("    [CONTRACT] healthAfterWithdrawal: \(healthAfterWithdrawal)")
        }

        if healthAfterWithdrawal >= targetHealth {
            // The position is already at or above the target health, so we don't need to deposit anything.
            return 0.0
        }

        // For situations where the required deposit will BOTH pay off debt and accumulate collateral, we keep
        // track of the number of tokens that went towards paying off debt.
        var debtTokenCount: UFix128 = 0.0
        let maybeBalance = depositBalance
        if maybeBalance?.scaledBalance?.direction == FlowALPModels.BalanceDirection.Debit {
            // The user has a debt position in the given token, we start by looking at the health impact of paying off
            // the entire debt.
            let debtBalance = maybeBalance!.scaledBalance.quantity
            let trueDebtTokenCount = FlowALPMath.scaledBalanceToTrueBalance(
                debtBalance,
                interestIndex: depositDebitInterestIndex
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
                let requiredEffectiveDebt = effectiveDebtAfterWithdrawal
                    - (effectiveCollateralAfterWithdrawal / targetHealth)
                // The amount of the token to pay back, in units of the token.
                let paybackAmount = (requiredEffectiveDebt * depositBorrowFactor) / depositPrice
                if isDebugLogging {
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
        let requiredEffectiveCollateral = (healthChangeU * effectiveDebtAfterWithdrawal) / depositCollateralFactor

        // The amount of the token to deposit, in units of the token.
        let collateralTokenCount = requiredEffectiveCollateral / depositPrice
        if isDebugLogging {
            log("    [CONTRACT] requiredEffectiveCollateral: \(requiredEffectiveCollateral)")
            log("    [CONTRACT] collateralTokenCount: \(collateralTokenCount)")
            log("    [CONTRACT] debtTokenCount: \(debtTokenCount)")
            log("    [CONTRACT] collateralTokenCount + debtTokenCount: \(collateralTokenCount) + \(debtTokenCount) = \(collateralTokenCount + debtTokenCount)")
        }

        // debtTokenCount is the number of tokens that went towards debt, zero if there was no debt.
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

        let effectiveBalance = tokenSnapshot.effectiveBalance(balance: after)
        return balanceSheet.withReplacedTokenBalance(
            tokenType: depositType,
            effectiveBalance: effectiveBalance
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
    ): FlowALPModels.Balance {
        let direction = balance?.scaledBalance?.direction ?? FlowALPModels.BalanceDirection.Credit
        let scaledBalance = balance?.scaledBalance?.quantity ?? 0.0

        switch direction {
            case FlowALPModels.BalanceDirection.Credit:
                // Currently has credit — deposit adds more credit.
                let trueCredit = FlowALPMath.scaledBalanceToTrueBalance(
                    scaledBalance, interestIndex: tokenSnapshot.creditIndex
                )
                return FlowALPModels.Balance(
                    direction: FlowALPModels.BalanceDirection.Credit,
                    quantity: trueCredit + depositAmount
                )

            case FlowALPModels.BalanceDirection.Debit:
                // Currently in debt — deposit pays it down, possibly flipping to credit.
                let trueDebt = FlowALPMath.scaledBalanceToTrueBalance(
                    scaledBalance, interestIndex: tokenSnapshot.debitIndex
                )
                if trueDebt >= depositAmount {
                    return FlowALPModels.Balance(
                        direction: FlowALPModels.BalanceDirection.Debit,
                        quantity: trueDebt - depositAmount
                    )
                } else {
                    return FlowALPModels.Balance(
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
            // The position is already at or below the provided target health, so we can't withdraw anything.
            return 0.0
        }

        // For situations where the available withdrawal will BOTH draw down collateral and create debt, we keep
        // track of the number of tokens that are available from collateral
        var collateralTokenCount: UFix128 = 0.0

        let maybeBalance = withdrawBalance
        if maybeBalance?.scaledBalance?.direction == FlowALPModels.BalanceDirection.Credit {
            // The user has a credit position in the withdraw token, we start by looking at the health impact of pulling out all
            // of that collateral
            let creditBalance = maybeBalance!.scaledBalance.quantity
            let trueCredit = FlowALPMath.scaledBalanceToTrueBalance(
                creditBalance,
                interestIndex: withdrawCreditInterestIndex
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
                if isDebugLogging {
                    log("    [CONTRACT] availableEffectiveValue: \(availableEffectiveValue)")
                }

                // The amount of the token we can take using that amount of health
                let availableTokenCount = (availableEffectiveValue / withdrawCollateralFactor) / withdrawPrice
                if isDebugLogging {
                    log("    [CONTRACT] availableTokenCount: \(availableTokenCount)")
                }

                return FlowALPMath.toUFix64RoundDown(availableTokenCount)
            } else {
                // We can flip this credit position into a debit position, before hitting the target health.
                // We have logic below that can determine health changes for debit positions. We've copied it here
                // with an added handling for the case where the health after deposit is an edgecase
                collateralTokenCount = trueCredit
                effectiveCollateralAfterDeposit = effectiveCollateralAfterDeposit - collateralEffectiveValue
                if isDebugLogging {
                    log("    [CONTRACT] collateralTokenCount: \(collateralTokenCount)")
                    log("    [CONTRACT] effectiveCollateralAfterDeposit: \(effectiveCollateralAfterDeposit)")
                }

                // We can calculate the available debt increase that would bring us to the target health
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

        // At this point, we're either dealing with a position that didn't have a credit balance in the withdraw
        // token, or we've accounted for the credit balance and adjusted the effective collateral above.

        // We can calculate the available debt increase that would bring us to the target health
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
