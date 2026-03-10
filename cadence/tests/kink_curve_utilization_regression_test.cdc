import Test
import "FlowToken"
import "FlowALPv0"
import "FlowALPModels"
import "FlowALPInterestRates"
import "test_helpers.cdc"

// This file guards against the historical KinkCurve utilization bug and keeps
// the original semantic mismatch documented in one place.
//
// Historical bug:
// - The old KinkCurve formula computed utilization as:
//     debitBalance / (creditBalance + debitBalance)
// - That only works if `creditBalance` means REMAINING AVAILABLE LIQUIDITY.
// - But FlowALP's live accounting uses `totalCreditBalance` to mean total
//   creditor claims, i.e. total supplied.
//
// Example of the mismatch:
// - 100 supplied
// - 90 borrowed
// - 10 idle liquidity left in the pool
//
// If `creditBalance` means remaining liquidity:
// - utilization = 90 / (10 + 90) = 90%
//
// If `creditBalance` means total supplied:
// - utilization = 90 / (100 + 90) = 47.4%
//
// The bug survived because direct curve tests were easy to write using
// hand-picked "remaining liquidity" inputs, while the live pool always passed
// total supplied, i.e. creditor claims, into the same parameter.
//
// After the fix, both direct KinkCurve calls and TokenState accounting must use
// the same meaning:
//   creditBalance = total creditor claims, i.e. total supplied
//
// These tests ensure a pool with 100 supplied and 90 borrowed is priced as 90%
// utilization in both paths.

access(all)
fun setup() {
    deployContracts()
}

access(all)
fun test_regression_KinkCurve_direct_curve_uses_total_supplied_semantics() {
    let curve = FlowALPInterestRates.KinkCurve(
        optimalUtilization: 0.80,
        baseRate: 0.01,
        slope1: 0.04,
        slope2: 0.60
    )

    // Direct curve calls must use total supplied semantics, matching the pool.
    let rate = curve.interestRate(creditBalance: 100.0, debitBalance: 90.0)

    Test.assertEqual(0.35 as UFix128, rate)
}

access(all)
fun test_regression_TokenState_90_borrow_of_100_supply_should_price_at_90_percent_utilization() {
    let curve = FlowALPInterestRates.KinkCurve(
        optimalUtilization: 0.80,
        baseRate: 0.01,
        slope1: 0.04,
        slope2: 0.60
    )

    var tokenState = FlowALPModels.TokenStateImplv1(
        tokenType: Type<@FlowToken.Vault>(),
        interestCurve: curve,
        depositRate: 1.0,
        depositCapacityCap: 1_000.0
    )

    // Realistic pool state: 100 total supplied, 90 total borrowed.
    // TokenState stores those values directly as total credit and total debt,
    // so this path verifies the live accounting matches the direct curve path.
    tokenState.increaseCreditBalance(by: 100.0)
    tokenState.increaseDebitBalance(by: 90.0)

    let actualYearlyRate = curve.interestRate(
        creditBalance: tokenState.getTotalCreditBalance(),
        debitBalance: tokenState.getTotalDebitBalance()
    )

    // The live pool path should match the direct curve path above. If it does
    // not, `creditBalance` semantics have drifted again.
    Test.assert(
        actualYearlyRate == 0.35,
        message:
            "Regression: 100 supplied / 90 borrowed should price at 90% utilization (0.35 APY), but current accounting passed creditBalance="
            .concat(tokenState.getTotalCreditBalance().toString())
            .concat(" and debitBalance=")
            .concat(tokenState.getTotalDebitBalance().toString())
            .concat(", producing ")
            .concat(actualYearlyRate.toString())
            .concat(" instead")
    )
}
