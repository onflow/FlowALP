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
    /// @param initialBalanceSheet: The position's current effective collateral and debt (with per-token maps)
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

    /// Computes the minimum true balance of a given token T required for a balance sheet to achieve a target health.
    ///
    /// The result is the minimum-magnitude balance (which may be credit or debit direction) such that,
    /// if the token's effective contribution were recomputed from this balance, the overall health
    /// would equal the target. When the rest of the balance sheet already exceeds the target health
    /// without any contribution from this token, the result is a debit (debt) balance representing the
    /// maximum debt the token can carry. Otherwise, it is a credit (collateral) balance representing
    /// the minimum collateral needed.
    ///
    /// @param tokenType: The type of the token to solve for (T).
    /// @param tokenSnapshot: Snapshot of the token's price, interest indices, and risk params.
    /// @param balanceSheet: The position's current balance sheet.
    /// @param targetHealth: The target health ratio to achieve.
    /// @return The minimum true balance of the token required to achieve the target health.
    access(self) fun requiredBalanceForTargetHealth(
        tokenType: Type,
        tokenSnapshot: FlowALPModels.TokenSnapshot,
        balanceSheet: FlowALPModels.BalanceSheet,
        targetHealth: UFix128
    ): FlowALPModels.Balance {
        let tokenEffectiveCollateral = balanceSheet.effectiveCollateralByToken[tokenType] ?? 0.0
        let tokenEffectiveDebt = balanceSheet.effectiveDebtByToken[tokenType] ?? 0.0
        // Remove the token's current contribution to isolate everything else.
        let Ce_others = balanceSheet.effectiveCollateral - tokenEffectiveCollateral
        let De_others = balanceSheet.effectiveDebt - tokenEffectiveDebt

        let price = tokenSnapshot.price
        let CF = tokenSnapshot.risk.getCollateralFactor()
        let BF = tokenSnapshot.risk.getBorrowFactor()

        // Given the health formula H = Ce/De, we find the value for Ce needed for the target health,
        // given the effective debt without T's contribution.
        let requiredEffectiveCollateral = targetHealth * De_others
        if requiredEffectiveCollateral > Ce_others {
            // The rest of the balance sheet does not reach target health, so T must have a credit balance

            // The required contribution of T to overall effective collateral (denominated in $)
            let targetTokenEffectiveCollateral = requiredEffectiveCollateral - Ce_others
            // The required credit balance to achieve this contribution (denominated in T)
            // Re-arrange the effective collateral formula Ce=(Nc)(Pc)(Fc) -> Nc=Ce/(Pc*Fc)
            let minCredit = targetTokenEffectiveCollateral / (price * CF)
            return FlowALPModels.Balance(
                direction: FlowALPModels.BalanceDirection.Credit,
                quantity: minCredit
            )
        } else {
            // The rest of the balance sheet already exceeds the target health, leaving room for T-denominated debt

            // The required contribution of T to overall effective debt (denominated in $)
            // H = Ce_others/(De_others+De_T) -> solve for De_T
            let targetTokenEffectiveDebt = (Ce_others / targetHealth) - De_others
            // The required credit balance to achieve this contribution (denominated in T)
            // Re-arrange the effective debt formula De=(Nd)(Pd)/(Fd) -> Nd=(De*Fd)/Pd
            let maxDebt = (targetTokenEffectiveDebt * BF) / price
            return FlowALPModels.Balance(
                direction: FlowALPModels.BalanceDirection.Debit,
                quantity: maxDebt
            )
        }
    }

    /// Computes the minimum deposit to bring the initial balance to a target balance.
    ///
    /// Returns the magnitude of the deposit needed to move from the initial balance to the target balance.
    /// If initial is already greater than or equal to target, returns 0.
    ///
    /// @param initial: The current true balance.
    /// @param target: The target true balance.
    /// @return The deposit size (always >= 0).
    access(self) fun minDepositForTargetBalance(
        initial: FlowALPModels.Balance,
        target: FlowALPModels.Balance
    ): UFix128 {
        let Credit = FlowALPModels.BalanceDirection.Credit 
        let Debit = FlowALPModels.BalanceDirection.Debit

        if target.direction == Credit && initial.direction == Credit {
            // Both credit: deposit needed only if target exceeds initial.
            return target.quantity > initial.quantity ? target.quantity - initial.quantity : 0.0
        } else if target.direction == Credit && initial.direction == Debit {
            // Initial is debit, target is credit: delta must cross zero.
            return initial.quantity + target.quantity
        } else if target.direction == Debit && initial.direction == Credit {
            // Initial already more favorable (credit) than target (debit): no deposit needed.
            return 0.0
        } else if target.direction == Debit && initial.direction == Debit {
            // Both debit: deposit needed only if initial debt exceeds target debt.
            return initial.quantity > target.quantity ? initial.quantity - target.quantity : 0.0
        }
        panic("unreachable")
    }

    /// Computes the maximum withdrawal to bring the initial balance to a target balance.
    ///
    /// Returns the magnitude of the withdrawal needed to move from the initial balance to the target balance.
    /// If initial is already less than or equal to target, returns 0.
    ///
    /// @param initial: The current true balance.
    /// @param target: The target true balance.
    /// @return The withdrawal size (always >= 0).
    access(self) fun maxWithdrawalForTargetBalance(
        initial: FlowALPModels.Balance,
        target: FlowALPModels.Balance
    ): UFix128 {
        let Credit = FlowALPModels.BalanceDirection.Credit 
        let Debit = FlowALPModels.BalanceDirection.Debit

        if target.direction == Debit && initial.direction == Debit {
            // Both debit: withdrawal available only if target debt exceeds initial.
            return target.quantity > initial.quantity ? target.quantity - initial.quantity : 0.0
        } else if target.direction == Debit && initial.direction == Credit {
            // Initial is credit, target is debit: delta must cross zero.
            return initial.quantity + target.quantity
        } else if target.direction == Credit && initial.direction == Debit {
            // Initial already more unfavorable (debit) than target (credit): no withdrawal available.
            return 0.0
        } else if target.direction == Credit && initial.direction == Credit {
            // Both credit: withdrawal available only if initial credit exceeds target.
            return initial.quantity > target.quantity ? initial.quantity - target.quantity : 0.0
        }
        panic("unreachable")
    }

    /// Computes the amount of a given token that must be deposited to bring a position to a target health.
    ///
    /// Determines the minimum true balance the token must have to achieve the target health,
    /// then computes the credit-direction delta from the current balance to that target balance.
    /// The delta represents the required deposit amount.
    ///
    /// @param initialBalance: The position's existing (scaled) balance for the deposit token, if any. If nil, considered as zero.
    /// @param depositType: The type of token being deposited.
    /// @param depositSnapshot: Snapshot of the deposit token's price, interest indices, and risk params.
    /// @param initialBalanceSheet: The position's current balance sheet.
    /// @param targetHealth: The target health ratio to achieve.
    /// @return The amount of tokens (in UFix64) required to reach the target health.
    access(account) fun computeRequiredDepositForHealth(
        initialBalance maybeInitialBalance: FlowALPModels.InternalBalance?,
        depositType: Type,
        depositSnapshot: FlowALPModels.TokenSnapshot,
        initialBalanceSheet: FlowALPModels.BalanceSheet,
        targetHealth: UFix128
    ): UFix64 {
        if initialBalanceSheet.health >= targetHealth {
            return 0.0
        }

        let requiredBalance = self.requiredBalanceForTargetHealth(
            tokenType: depositType,
            tokenSnapshot: depositSnapshot,
            balanceSheet: initialBalanceSheet,
            targetHealth: targetHealth
        )

        let initialBalance = maybeInitialBalance ?? FlowALPModels.makeZeroInternalBalance()
        let currentTrueBalance = depositSnapshot.trueBalance(balance: initialBalance)

        let delta = self.minDepositForTargetBalance(initial: currentTrueBalance, target: requiredBalance)
        return FlowALPMath.toUFix64RoundUp(delta)
    }

    /// Computes adjusted effective collateral and debt after a hypothetical deposit.
    ///
    /// This function determines how a deposit would affect the position's balance sheet,
    /// accounting for whether the position holds a credit (collateral) or debit (debt) balance
    /// in the deposited token. If the position has debt in the token, the deposit may
    /// either pay down debt, or pay it off entirely and create new collateral.
    ///
    /// @param initialBalanceSheet: The position's current effective collateral and debt (with per-token maps)
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
    /// Determines the minimum true balance the token must have to maintain the target health,
    /// then computes the debit-direction delta from the current balance to that target balance.
    /// The delta represents the maximum available withdrawal amount.
    ///
    /// @param withdrawBalance: The position's existing (scaled) balance for the withdrawn token, if any. If nil, considered as zero.
    /// @param withdrawType: The type of token being withdrawn.
    /// @param withdrawSnapshot: Snapshot of the withdrawn token's price, interest indices, and risk params.
    /// @param initialBalanceSheet: The position's current balance sheet.
    /// @param targetHealth: The minimum health ratio to maintain.
    /// @return The maximum amount of tokens (in UFix64) that can be withdrawn.
    access(account) fun computeAvailableWithdrawal(
        withdrawBalance: FlowALPModels.InternalBalance?,
        withdrawType: Type,
        withdrawSnapshot: FlowALPModels.TokenSnapshot,
        initialBalanceSheet: FlowALPModels.BalanceSheet,
        targetHealth: UFix128
    ): UFix64 {
        if initialBalanceSheet.health <= targetHealth {
            return 0.0
        }

        let requiredBalance = self.requiredBalanceForTargetHealth(
            tokenType: withdrawType,
            tokenSnapshot: withdrawSnapshot,
            balanceSheet: initialBalanceSheet,
            targetHealth: targetHealth
        )

        let initialBalance = withdrawBalance ?? FlowALPModels.makeZeroInternalBalance()
        let currentTrueBalance = withdrawSnapshot.trueBalance(balance: initialBalance)

        let delta = self.maxWithdrawalForTargetBalance(initial: currentTrueBalance, target: requiredBalance)
        return FlowALPMath.toUFix64RoundDown(delta)
    }
}
