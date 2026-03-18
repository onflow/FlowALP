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
    /// @param tokenSnapshot: Snapshot of the withdrawn token's price, interest indices, and risk params
    /// @return A new BalanceSheet reflecting the effective collateral and debt after the withdrawal
    access(account) fun computeAdjustedBalancesAfterWithdrawal(
        initialBalanceSheet: FlowALPModels.BalanceSheet,
        withdrawBalance: FlowALPModels.InternalBalance?,
        withdrawType: Type,
        withdrawAmount: UFix64,
        tokenSnapshot: FlowALPModels.TokenSnapshot
    ): FlowALPModels.BalanceSheet {
        if withdrawAmount == 0.0 {
            return initialBalanceSheet
        }

        let withdrawAmountU = UFix128(withdrawAmount)

        // Compute the post-withdrawal true balance and direction.
        let trueBalanceAfterWithdrawal = self.trueBalanceAfterDelta(
            balance: withdrawBalance,
            delta: FlowALPModels.Balance(
                direction: FlowALPModels.BalanceDirection.Debit,
                quantity: withdrawAmountU
            ),
            tokenSnapshot: tokenSnapshot
        )

        // Compute the effective collateral or debt, and return the updated balance sheet.
        let effectiveBalance = tokenSnapshot.effectiveBalance(balance: trueBalanceAfterWithdrawal)
        return initialBalanceSheet.withReplacedTokenBalance(
            tokenType: withdrawType,
            effectiveBalance: effectiveBalance
        )
    }

    /// Computes the resulting true balance after applying a signed delta to an InternalBalance.
    ///
    /// The input balance and delta may have either credit or debit direction. They each may have different directions.
    /// A credit-direction delta increases credit / pays down debt. A debit-direction delta increases debt / draws down credit.
    /// The result may flip direction if the delta exceeds the current balance.
    ///
    /// @param balance: The initial balance, represented as an InternalBalance (hence, scaled). If nil, considered as zero.
    /// @param delta: The deposit or withdrawal to apply to the balance.
    /// @param tokenSnapshot: The TokenSnapshot for the token type denominating the balance and delta parameters.
    /// @return The true balance after applying the delta.
    access(self) fun trueBalanceAfterDelta(
        balance maybeInitialBalance: FlowALPModels.InternalBalance?,
        delta: FlowALPModels.Balance,
        tokenSnapshot: FlowALPModels.TokenSnapshot
    ): FlowALPModels.Balance {
        // A nil input balance means the initial balance is zero.
        let initialBalance = maybeInitialBalance ?? FlowALPModels.makeZeroInternalBalance()
        let trueBal = tokenSnapshot.trueBalance(balance: initialBalance)

        // Same direction — delta reinforces the current balance.
        if trueBal.direction == delta.direction {
            return FlowALPModels.Balance(
                direction: trueBal.direction,
                quantity: trueBal.quantity + delta.quantity
            )
        }

        // Opposite direction — delta offsets the current balance, possibly flipping.
        if trueBal.quantity >= delta.quantity {
            // delta decreases balance but does not flip sign
            return FlowALPModels.Balance(
                direction: trueBal.direction,
                quantity: trueBal.quantity - delta.quantity
            )
        } else {
            // delta flips sign of balance
            return FlowALPModels.Balance(
                direction: delta.direction,
                quantity: delta.quantity - trueBal.quantity
            )
        }
    }

    /// Computes the amount of a given token that must be deposited to bring a position to a target health.
    ///
    /// This function handles the case where the deposit token may have an existing debit (debt) balance.
    /// If so, the deposit first pays down debt before accumulating as collateral. The computation
    /// determines the minimum deposit required to reach the target health, accounting for both
    /// debt repayment and collateral accumulation as needed.
    ///
    /// @param depositBalance: The position's existing balance for the deposit token, if any
    /// @param depositSnapshot: Snapshot of the deposit token's price, interest indices, and risk params
    /// @param initialHealthStatement: The position's current health statement (post any prior withdrawal)
    /// @param targetHealth: The target health ratio to achieve
    /// @return The amount of tokens (in UFix64) required to reach the target health
    access(account) fun computeRequiredDepositForHealth(
        depositBalance: FlowALPModels.InternalBalance?,
        depositSnapshot: FlowALPModels.TokenSnapshot,
        initialHealthStatement: FlowALPModels.HealthStatement,
        targetHealth: UFix128
    ): UFix64 {
        let initialEffectiveCollateral = initialHealthStatement.effectiveCollateral
        var effectiveDebt = initialHealthStatement.effectiveDebt
        var health = initialHealthStatement.health

        if health >= targetHealth {
            // The position is already at or above the target health, so we don't need to deposit anything.
            return 0.0
        }

        // For situations where the required deposit will BOTH pay off debt and accumulate collateral, we keep
        // track of the number of tokens that went towards paying off debt.
        var debtTokenCount: UFix128 = 0.0
        let maybeBalance = depositBalance
        if maybeBalance?.getScaledBalance()?.direction == FlowALPModels.BalanceDirection.Debit {
            // The user has a debt position in the given token, we start by looking at the health impact of paying off
            // the entire debt.
            let trueDebtTokenCount = depositSnapshot.trueBalance(balance: maybeBalance!).quantity
            let debtEffectiveValue = (depositSnapshot.price * trueDebtTokenCount) / depositSnapshot.risk.getBorrowFactor()

            // Ensure we don't underflow - if debtEffectiveValue is greater than effectiveDebt,
            // it means we can pay off all debt
            var effectiveDebtAfterPayment: UFix128 = 0.0
            if debtEffectiveValue <= effectiveDebt {
                effectiveDebtAfterPayment = effectiveDebt - debtEffectiveValue
            }

            // Check what the new health would be if we paid off all of this debt
            let potentialHealth = FlowALPMath.healthComputation(
                effectiveCollateral: initialEffectiveCollateral,
                effectiveDebt: effectiveDebtAfterPayment
            )

            // Does paying off all of the debt reach the target health? Then we're done.
            if potentialHealth >= targetHealth {
                // We can reach the target health by paying off some or all of the debt. We can easily
                // compute how many units of the token would be needed to reach the target health.
                let requiredEffectiveDebt = effectiveDebt
                    - (initialEffectiveCollateral / targetHealth)
                // The amount of the token to pay back, in units of the token.
                let paybackAmount = (requiredEffectiveDebt * depositSnapshot.risk.getBorrowFactor()) / depositSnapshot.price
                return FlowALPMath.toUFix64RoundUp(paybackAmount)
            } else {
                // We can pay off the entire debt, but we still need to deposit more to reach the target health.
                // We have logic below that can determine the collateral deposition required to reach the target health
                // from this new health position. Rather than copy that logic here, we fall through into it. But first
                // we have to record the amount of tokens that went towards debt payback and adjust the effective
                // debt to reflect that it has been paid off.
                debtTokenCount = trueDebtTokenCount
                // Ensure we don't underflow
                if debtEffectiveValue <= effectiveDebt {
                    effectiveDebt = effectiveDebt - debtEffectiveValue
                } else {
                    effectiveDebt = 0.0
                }
                health = potentialHealth
            }
        }

        // At this point, we're either dealing with a position that didn't have a debt position in the deposit
        // token, or we've accounted for the debt payoff and adjusted the effective debt above.
        // Now we need to figure out how many tokens would need to be deposited (as collateral) to reach the
        // target health. We can rearrange the health equation to solve for the required collateral:

        // We need to increase the effective collateral from its current value to the required value, so we
        // multiply the required health change by the effective debt, and turn that into a token amount.
        let healthChangeU = targetHealth - health
        // TODO: apply the same logic as below to the early return blocks above
        let requiredEffectiveCollateral = (healthChangeU * effectiveDebt) / depositSnapshot.risk.getCollateralFactor()

        // The amount of the token to deposit, in units of the token.
        let collateralTokenCount = requiredEffectiveCollateral / depositSnapshot.price

        // debtTokenCount is the number of tokens that went towards debt, zero if there was no debt.
        return FlowALPMath.toUFix64Round(collateralTokenCount + debtTokenCount)
    }

    /// Computes adjusted effective collateral and debt after a hypothetical deposit.
    ///
    /// This function determines how a deposit would affect the position's balance sheet,
    /// accounting for whether the position holds a credit (collateral) or debit (debt) balance
    /// in the deposited token. If the position has debt in the token, the deposit may
    /// either pay down debt, or pay it off entirely and create new collateral.
    ///
    /// @param balanceSheet: The position's current effective collateral and debt (with per-token maps)
    /// @param depositBalance: The position's existing balance for the deposited token, if any
    /// @param depositType: The type of token being deposited
    /// @param depositAmount: The amount of tokens to deposit
    /// @param tokenSnapshot: Snapshot of the deposited token's price, interest indices, and risk params
    /// @return A new BalanceSheet reflecting the effective collateral and debt after the deposit
    access(account) fun computeAdjustedBalancesAfterDeposit(
        initialBalanceSheet: FlowALPModels.BalanceSheet,
        depositBalance: FlowALPModels.InternalBalance?,
        depositType: Type,
        depositAmount: UFix64,
        tokenSnapshot: FlowALPModels.TokenSnapshot
    ): FlowALPModels.BalanceSheet {
        if depositAmount == 0.0 {
            return initialBalanceSheet
        }

        let depositAmountU = UFix128(depositAmount)

        // Compute the post-deposit true balance and direction.
        let after = self.trueBalanceAfterDelta(
            balance: depositBalance,
            delta: FlowALPModels.Balance(
                direction: FlowALPModels.BalanceDirection.Credit,
                quantity: depositAmountU
            ),
            tokenSnapshot: tokenSnapshot
        )

        // Compute the effective collateral or debt, and return the updated balance sheet.
        let effectiveBalance = tokenSnapshot.effectiveBalance(balance: after)
        return initialBalanceSheet.withReplacedTokenBalance(
            tokenType: depositType,
            effectiveBalance: effectiveBalance
        )
    }

    /// Computes the maximum amount of a given token that can be withdrawn while maintaining a target health.
    ///
    /// @param withdrawBalance: The position's existing balance for the withdrawn token, if any
    /// @param withdrawSnapshot: Snapshot of the withdrawn token's price, interest indices, and risk params
    /// @param initialHealthStatement: The position's current health statement (post any prior deposit)
    /// @param targetHealth: The minimum health ratio to maintain
    /// @return The maximum amount of tokens (in UFix64) that can be withdrawn
    access(account) fun computeAvailableWithdrawal(
        withdrawBalance: FlowALPModels.InternalBalance?,
        withdrawSnapshot: FlowALPModels.TokenSnapshot,
        initialHealthStatement: FlowALPModels.HealthStatement,
        targetHealth: UFix128
    ): UFix64 {
        var effectiveCollateral = initialHealthStatement.effectiveCollateral
        let effectiveDebt = initialHealthStatement.effectiveDebt
        let initialHealth = initialHealthStatement.health

        if initialHealth <= targetHealth {
            // The position is already at or below the provided target health, so we can't withdraw anything.
            return 0.0
        }

        // For situations where the available withdrawal will BOTH draw down collateral and create debt, we keep
        // track of the number of tokens that are available from collateral
        var collateralTokenCount: UFix128 = 0.0

        let maybeBalance = withdrawBalance
        if maybeBalance?.getScaledBalance()?.direction == FlowALPModels.BalanceDirection.Credit {
            // The user has a credit position in the withdraw token, we start by looking at the health impact of pulling out all
            // of that collateral
            let trueCredit = withdrawSnapshot.trueBalance(balance: maybeBalance!).quantity
            let collateralEffectiveValue = (withdrawSnapshot.price * trueCredit) * withdrawSnapshot.risk.getCollateralFactor()

            // Check what the new health would be if we took out all of this collateral
            let potentialHealth = FlowALPMath.healthComputation(
                effectiveCollateral: effectiveCollateral - collateralEffectiveValue,
                effectiveDebt: effectiveDebt
            )

            // Does drawing down all of the collateral go below the target health? Then the max withdrawal comes from collateral only.
            if potentialHealth <= targetHealth {
                // We will hit the health target before using up all of the withdraw token credit. We can easily
                // compute how many units of the token would bring the position down to the target health.
                let availableEffectiveValue = effectiveCollateral - (targetHealth * effectiveDebt)

                // The amount of the token we can take using that amount of health
                let availableTokenCount = (availableEffectiveValue / withdrawSnapshot.risk.getCollateralFactor()) / withdrawSnapshot.price

                return FlowALPMath.toUFix64RoundDown(availableTokenCount)
            } else {
                // We can flip this credit position into a debit position, before hitting the target health.
                collateralTokenCount = trueCredit
                effectiveCollateral = effectiveCollateral - collateralEffectiveValue

                // We can calculate the available debt increase that would bring us to the target health
                let availableDebtIncrease = (effectiveCollateral / targetHealth) - effectiveDebt
                let availableTokens = (availableDebtIncrease * withdrawSnapshot.risk.getBorrowFactor()) / withdrawSnapshot.price

                return FlowALPMath.toUFix64RoundDown(availableTokens + collateralTokenCount)
            }
        }

        // At this point, we're either dealing with a position that didn't have a credit balance in the withdraw
        // token, or we've accounted for the credit balance and adjusted the effective collateral above.

        // We can calculate the available debt increase that would bring us to the target health
        let availableDebtIncrease = (effectiveCollateral / targetHealth) - effectiveDebt
        let availableTokens = (availableDebtIncrease * withdrawSnapshot.risk.getBorrowFactor()) / withdrawSnapshot.price

        return FlowALPMath.toUFix64RoundDown(availableTokens + collateralTokenCount)
    }
}
