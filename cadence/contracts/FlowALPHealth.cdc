import "FlowALPMath"
import "FlowALPModels"

access(all) contract FlowALPHealth {

    /// Computes effective collateral/debt after a hypothetical withdrawal.
    access(all) fun computeAdjustedBalancesAfterWithdrawal(
        balanceSheet: FlowALPModels.BalanceSheet,
        withdrawBalance: FlowALPModels.InternalBalance?,
        withdrawAmount: UFix64,
        withdrawPrice: UFix128,
        withdrawBorrowFactor: UFix128,
        withdrawCollateralFactor: UFix128,
        withdrawCreditInterestIndex: UFix128
    ): FlowALPModels.BalanceSheet {
        var effectiveCollateralAfterWithdrawal = balanceSheet.effectiveCollateral
        var effectiveDebtAfterWithdrawal = balanceSheet.effectiveDebt

        if withdrawAmount == 0.0 {
            return FlowALPModels.BalanceSheet(
                effectiveCollateral: effectiveCollateralAfterWithdrawal,
                effectiveDebt: effectiveDebtAfterWithdrawal
            )
        }

        let withdrawAmountU = UFix128(withdrawAmount)
        let direction = withdrawBalance?.direction ?? FlowALPModels.BalanceDirection.Debit
        let scaledBalance = withdrawBalance?.scaledBalance ?? 0.0

        switch direction {
            case FlowALPModels.BalanceDirection.Debit:
                effectiveDebtAfterWithdrawal = balanceSheet.effectiveDebt +
                    (withdrawAmountU * withdrawPrice) / withdrawBorrowFactor

            case FlowALPModels.BalanceDirection.Credit:
                let trueCollateral = FlowALPMath.scaledBalanceToTrueBalance(
                    scaledBalance,
                    interestIndex: withdrawCreditInterestIndex
                )
                if trueCollateral >= withdrawAmountU {
                    effectiveCollateralAfterWithdrawal = balanceSheet.effectiveCollateral -
                        (withdrawAmountU * withdrawPrice) * withdrawCollateralFactor
                } else {
                    effectiveDebtAfterWithdrawal = balanceSheet.effectiveDebt +
                        ((withdrawAmountU - trueCollateral) * withdrawPrice) / withdrawBorrowFactor
                    effectiveCollateralAfterWithdrawal = balanceSheet.effectiveCollateral -
                        (trueCollateral * withdrawPrice) * withdrawCollateralFactor
                }
        }

        return FlowALPModels.BalanceSheet(
            effectiveCollateral: effectiveCollateralAfterWithdrawal,
            effectiveDebt: effectiveDebtAfterWithdrawal
        )
    }

    /// Computes how much of depositType is required to reach target health.
    access(all) fun computeRequiredDepositForHealth(
        depositBalance: FlowALPModels.InternalBalance?,
        depositDebitInterestIndex: UFix128,
        depositPrice: UFix128,
        depositBorrowFactor: UFix128,
        depositCollateralFactor: UFix128,
        effectiveCollateralAfterWithdrawal: UFix128,
        effectiveDebtAfterWithdrawal: UFix128,
        targetHealth: UFix128
    ): UFix64 {
        var debtAfter = effectiveDebtAfterWithdrawal
        var healthAfterWithdrawal = FlowALPMath.healthComputation(
            effectiveCollateral: effectiveCollateralAfterWithdrawal,
            effectiveDebt: debtAfter
        )

        if healthAfterWithdrawal >= targetHealth {
            return 0.0
        }

        // Portion of required deposit consumed by debt paydown before collateralization.
        var debtTokenCount: UFix128 = 0.0

        if depositBalance?.direction == FlowALPModels.BalanceDirection.Debit {
            let debtBalance = depositBalance!.scaledBalance
            let trueDebtTokenCount = FlowALPMath.scaledBalanceToTrueBalance(
                debtBalance,
                interestIndex: depositDebitInterestIndex
            )
            let debtEffectiveValue = (depositPrice * trueDebtTokenCount) / depositBorrowFactor

            var effectiveDebtAfterPayment: UFix128 = 0.0
            if debtEffectiveValue <= debtAfter {
                effectiveDebtAfterPayment = debtAfter - debtEffectiveValue
            }

            let potentialHealth = FlowALPMath.healthComputation(
                effectiveCollateral: effectiveCollateralAfterWithdrawal,
                effectiveDebt: effectiveDebtAfterPayment
            )

            if potentialHealth >= targetHealth {
                let requiredEffectiveDebt = debtAfter - (effectiveCollateralAfterWithdrawal / targetHealth)
                let paybackAmount = (requiredEffectiveDebt * depositBorrowFactor) / depositPrice
                return FlowALPMath.toUFix64RoundUp(paybackAmount)
            } else {
                debtTokenCount = trueDebtTokenCount
                if debtEffectiveValue <= debtAfter {
                    debtAfter = debtAfter - debtEffectiveValue
                } else {
                    debtAfter = 0.0
                }
                healthAfterWithdrawal = potentialHealth
            }
        }

        let healthChange = targetHealth - healthAfterWithdrawal
        let requiredEffectiveCollateral = (healthChange * debtAfter) / depositCollateralFactor
        let collateralTokenCount = requiredEffectiveCollateral / depositPrice

        return FlowALPMath.toUFix64Round(collateralTokenCount + debtTokenCount)
    }

    /// Computes effective collateral/debt after a hypothetical deposit.
    access(all) fun computeAdjustedBalancesAfterDeposit(
        balanceSheet: FlowALPModels.BalanceSheet,
        depositBalance: FlowALPModels.InternalBalance?,
        depositAmount: UFix64,
        depositPrice: UFix128,
        depositBorrowFactor: UFix128,
        depositCollateralFactor: UFix128,
        depositDebitInterestIndex: UFix128
    ): FlowALPModels.BalanceSheet {
        var effectiveCollateralAfterDeposit = balanceSheet.effectiveCollateral
        var effectiveDebtAfterDeposit = balanceSheet.effectiveDebt

        if depositAmount == 0.0 {
            return FlowALPModels.BalanceSheet(
                effectiveCollateral: effectiveCollateralAfterDeposit,
                effectiveDebt: effectiveDebtAfterDeposit
            )
        }

        let depositAmountCasted = UFix128(depositAmount)
        let direction = depositBalance?.direction ?? FlowALPModels.BalanceDirection.Credit
        let scaledBalance = depositBalance?.scaledBalance ?? 0.0

        switch direction {
            case FlowALPModels.BalanceDirection.Credit:
                effectiveCollateralAfterDeposit = balanceSheet.effectiveCollateral +
                    (depositAmountCasted * depositPrice) * depositCollateralFactor

            case FlowALPModels.BalanceDirection.Debit:
                let trueDebt = FlowALPMath.scaledBalanceToTrueBalance(
                    scaledBalance,
                    interestIndex: depositDebitInterestIndex
                )

                if trueDebt >= depositAmountCasted {
                    effectiveDebtAfterDeposit = balanceSheet.effectiveDebt -
                        (depositAmountCasted * depositPrice) / depositBorrowFactor
                } else {
                    effectiveDebtAfterDeposit = balanceSheet.effectiveDebt -
                        (trueDebt * depositPrice) / depositBorrowFactor
                    effectiveCollateralAfterDeposit = balanceSheet.effectiveCollateral +
                        (depositAmountCasted - trueDebt) * depositPrice * depositCollateralFactor
                }
        }

        return FlowALPModels.BalanceSheet(
            effectiveCollateral: effectiveCollateralAfterDeposit,
            effectiveDebt: effectiveDebtAfterDeposit
        )
    }

    /// Computes max withdrawable amount while staying at or above target health.
    access(all) fun computeAvailableWithdrawal(
        withdrawBalance: FlowALPModels.InternalBalance?,
        withdrawCreditInterestIndex: UFix128,
        withdrawPrice: UFix128,
        withdrawCollateralFactor: UFix128,
        withdrawBorrowFactor: UFix128,
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
        if healthAfterDeposit <= targetHealth {
            return 0.0
        }

        var collateralTokenCount: UFix128 = 0.0

        if withdrawBalance?.direction == FlowALPModels.BalanceDirection.Credit {
            let creditBalance = withdrawBalance!.scaledBalance
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
                let availableTokenCount = (availableEffectiveValue / withdrawCollateralFactor) / withdrawPrice
                return FlowALPMath.toUFix64RoundDown(availableTokenCount)
            } else {
                collateralTokenCount = trueCredit
                effectiveCollateralAfterDeposit = effectiveCollateralAfterDeposit - collateralEffectiveValue

                let availableDebtIncrease = (effectiveCollateralAfterDeposit / targetHealth) - effectiveDebtAfterDeposit
                let availableTokens = (availableDebtIncrease * withdrawBorrowFactor) / withdrawPrice
                return FlowALPMath.toUFix64RoundDown(availableTokens + collateralTokenCount)
            }
        }

        let availableDebtIncrease = (effectiveCollateralAfterDeposit / targetHealth) - effectiveDebtAfterDeposit
        let availableTokens = (availableDebtIncrease * withdrawBorrowFactor) / withdrawPrice
        return FlowALPMath.toUFix64RoundDown(availableTokens + collateralTokenCount)
    }
}
