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
    /// @param balanceSheet: The position's current effective collateral and debt
    /// @param withdrawBalance: The position's existing balance for the withdrawn token, if any
    /// @param withdrawAmount: The amount of tokens to withdraw
    /// @param withdrawPrice: The oracle price of the withdrawn token
    /// @param withdrawBorrowFactor: The borrow factor applied to debt in the withdrawn token
    /// @param withdrawCollateralFactor: The collateral factor applied to collateral in the withdrawn token
    /// @param withdrawCreditInterestIndex: The credit interest index for the withdrawn token;
    ///        must be non-nil when the position has a credit balance in this token, nil otherwise
    /// @param isDebugLogging: Whether to emit debug log messages
    /// @return A new BalanceSheet reflecting the effective collateral and debt after the withdrawal
    access(all) fun computeAdjustedBalancesAfterWithdrawal(
        balanceSheet: FlowALPModels.BalanceSheet,
        withdrawBalance: FlowALPModels.InternalBalance?,
        withdrawAmount: UFix64,
        withdrawPrice: UFix128,
        withdrawBorrowFactor: UFix128,
        withdrawCollateralFactor: UFix128,
        withdrawCreditInterestIndex: UFix128?,
        isDebugLogging: Bool
    ): FlowALPModels.BalanceSheet {
        var effectiveCollateralAfterWithdrawal = balanceSheet.effectiveCollateral
        var effectiveDebtAfterWithdrawal = balanceSheet.effectiveDebt

        if withdrawAmount == 0.0 {
            return FlowALPModels.BalanceSheet(
                effectiveCollateral: effectiveCollateralAfterWithdrawal,
                effectiveDebt: effectiveDebtAfterWithdrawal
            )
        }
        if isDebugLogging {
            log("    [CONTRACT] effectiveCollateralAfterWithdrawal: \(effectiveCollateralAfterWithdrawal)")
            log("    [CONTRACT] effectiveDebtAfterWithdrawal: \(effectiveDebtAfterWithdrawal)")
        }

        let withdrawAmountU = UFix128(withdrawAmount)
        let withdrawPrice2 = withdrawPrice
        let withdrawBorrowFactor2 = withdrawBorrowFactor
        let balance = withdrawBalance
        let direction = balance?.direction ?? FlowALPModels.BalanceDirection.Debit
        let scaledBalance = balance?.scaledBalance ?? 0.0

        switch direction {
            case FlowALPModels.BalanceDirection.Debit:
                // If the position doesn't have any collateral for the withdrawn token,
                // we can just compute how much additional effective debt the withdrawal will create.
                effectiveDebtAfterWithdrawal = balanceSheet.effectiveDebt +
                    (withdrawAmountU * withdrawPrice2) / withdrawBorrowFactor2

            case FlowALPModels.BalanceDirection.Credit:
                // The user has a collateral position in the given token, we need to figure out if this withdrawal
                // will flip over into debt, or just draw down the collateral.
                let trueCollateral = FlowALPMath.scaledBalanceToTrueBalance(
                    scaledBalance,
                    interestIndex: withdrawCreditInterestIndex!
                )
                let collateralFactor = withdrawCollateralFactor
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

    /// Computes the amount of a given token that must be deposited to bring a position to a target health.
    ///
    /// This function handles the case where the deposit token may have an existing debit (debt) balance.
    /// If so, the deposit first pays down debt before accumulating as collateral. The computation
    /// determines the minimum deposit required to reach the target health, accounting for both
    /// debt repayment and collateral accumulation as needed.
    ///
    /// @param depositBalance: The position's existing balance for the deposit token, if any
    /// @param depositDebitInterestIndex: The debit interest index for the deposit token;
    ///        must be non-nil when the position has a debit balance in this token, nil otherwise
    /// @param depositPrice: The oracle price of the deposit token
    /// @param depositBorrowFactor: The borrow factor applied to debt in the deposit token
    /// @param depositCollateralFactor: The collateral factor applied to collateral in the deposit token
    /// @param effectiveCollateral: The position's current effective collateral (post any prior withdrawal)
    /// @param effectiveDebt: The position's current effective debt (post any prior withdrawal)
    /// @param targetHealth: The target health ratio to achieve
    /// @param isDebugLogging: Whether to emit debug log messages
    /// @return The amount of tokens (in UFix64) required to reach the target health
    // TODO(jord): ~100-line function - consider refactoring
    access(all) fun computeRequiredDepositForHealth(
        depositBalance: FlowALPModels.InternalBalance?,
        depositDebitInterestIndex: UFix128?,
        depositPrice: UFix128,
        depositBorrowFactor: UFix128,
        depositCollateralFactor: UFix128,
        effectiveCollateral: UFix128,
        effectiveDebt: UFix128,
        targetHealth: UFix128,
        isDebugLogging: Bool
    ): UFix64 {
        let effectiveCollateralAfterWithdrawal = effectiveCollateral
        var effectiveDebtAfterWithdrawal = effectiveDebt
        if isDebugLogging {
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
        if maybeBalance?.direction == FlowALPModels.BalanceDirection.Debit {
            // The user has a debt position in the given token, we start by looking at the health impact of paying off
            // the entire debt.
            let debtBalance = maybeBalance!.scaledBalance
            let trueDebtTokenCount = FlowALPMath.scaledBalanceToTrueBalance(
                debtBalance,
                interestIndex: depositDebitInterestIndex!
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
    /// This function determines how a deposit would affect the position's balance sheet,
    /// accounting for whether the position holds a credit (collateral) or debit (debt) balance
    /// in the deposited token. If the position has debt in the token, the deposit first pays
    /// down debt before accumulating as collateral.
    ///
    /// @param balanceSheet: The position's current effective collateral and debt
    /// @param depositBalance: The position's existing balance for the deposited token, if any
    /// @param depositAmount: The amount of tokens to deposit
    /// @param depositPrice: The oracle price of the deposited token
    /// @param depositBorrowFactor: The borrow factor applied to debt in the deposited token
    /// @param depositCollateralFactor: The collateral factor applied to collateral in the deposited token
    /// @param depositDebitInterestIndex: The debit interest index for the deposited token;
    ///        must be non-nil when the position has a debit balance in this token, nil otherwise
    /// @param isDebugLogging: Whether to emit debug log messages
    /// @return A new BalanceSheet reflecting the effective collateral and debt after the deposit
    access(all) fun computeAdjustedBalancesAfterDeposit(
        balanceSheet: FlowALPModels.BalanceSheet,
        depositBalance: FlowALPModels.InternalBalance?,
        depositAmount: UFix64,
        depositPrice: UFix128,
        depositBorrowFactor: UFix128,
        depositCollateralFactor: UFix128,
        depositDebitInterestIndex: UFix128?,
        isDebugLogging: Bool
    ): FlowALPModels.BalanceSheet {
        var effectiveCollateralAfterDeposit = balanceSheet.effectiveCollateral
        var effectiveDebtAfterDeposit = balanceSheet.effectiveDebt
        if isDebugLogging {
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
        let depositPriceCasted = depositPrice
        let depositBorrowFactorCasted = depositBorrowFactor
        let depositCollateralFactorCasted = depositCollateralFactor
        let balance = depositBalance
        let direction = balance?.direction ?? FlowALPModels.BalanceDirection.Credit
        let scaledBalance = balance?.scaledBalance ?? 0.0

        switch direction {
            case FlowALPModels.BalanceDirection.Credit:
                // If there's no debt for the deposit token,
                // we can just compute how much additional effective collateral the deposit will create.
                effectiveCollateralAfterDeposit = balanceSheet.effectiveCollateral +
                    (depositAmountCasted * depositPriceCasted) * depositCollateralFactorCasted

            case FlowALPModels.BalanceDirection.Debit:
                // The user has a debt position in the given token, we need to figure out if this deposit
                // will result in net collateral, or just bring down the debt.
                let trueDebt = FlowALPMath.scaledBalanceToTrueBalance(
                    scaledBalance,
                    interestIndex: depositDebitInterestIndex!
                )
                if isDebugLogging {
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
        if isDebugLogging {
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

    /// Computes the maximum amount of a given token that can be withdrawn while maintaining a target health.
    ///
    /// This function determines how many tokens are available for withdrawal, accounting for
    /// whether the position holds a credit (collateral) balance in the withdrawn token. If the
    /// position has collateral, the withdrawal may draw down collateral only, or exhaust it and
    /// create new debt. The function finds the maximum withdrawal that keeps health at or above
    /// the target.
    ///
    /// @param withdrawBalance: The position's existing balance for the withdrawn token, if any
    /// @param withdrawCreditInterestIndex: The credit interest index for the withdrawn token;
    ///        must be non-nil when the position has a credit balance in this token, nil otherwise
    /// @param withdrawPrice: The oracle price of the withdrawn token
    /// @param withdrawCollateralFactor: The collateral factor applied to collateral in the withdrawn token
    /// @param withdrawBorrowFactor: The borrow factor applied to debt in the withdrawn token
    /// @param effectiveCollateral: The position's current effective collateral (post any prior deposit)
    /// @param effectiveDebt: The position's current effective debt (post any prior deposit)
    /// @param targetHealth: The minimum health ratio to maintain
    /// @param isDebugLogging: Whether to emit debug log messages
    /// @return The maximum amount of tokens (in UFix64) that can be withdrawn
    // TODO(jord): ~100-line function - consider refactoring
    access(all) fun computeAvailableWithdrawal(
        withdrawBalance: FlowALPModels.InternalBalance?,
        withdrawCreditInterestIndex: UFix128?,
        withdrawPrice: UFix128,
        withdrawCollateralFactor: UFix128,
        withdrawBorrowFactor: UFix128,
        effectiveCollateral: UFix128,
        effectiveDebt: UFix128,
        targetHealth: UFix128,
        isDebugLogging: Bool
    ): UFix64 {
        var effectiveCollateralAfterDeposit = effectiveCollateral
        let effectiveDebtAfterDeposit = effectiveDebt

        let healthAfterDeposit = FlowALPMath.healthComputation(
            effectiveCollateral: effectiveCollateralAfterDeposit,
            effectiveDebt: effectiveDebtAfterDeposit
        )
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
        if maybeBalance?.direction == FlowALPModels.BalanceDirection.Credit {
            // The user has a credit position in the withdraw token, we start by looking at the health impact of pulling out all
            // of that collateral
            let creditBalance = maybeBalance!.scaledBalance
            let trueCredit = FlowALPMath.scaledBalanceToTrueBalance(
                creditBalance,
                interestIndex: withdrawCreditInterestIndex!
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
