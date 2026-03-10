import Test
import "FlowToken"
import "FlowALPv0"
import "FlowALPModels"
import "FlowALPInterestRates"
import "FlowALPMath"
import "test_helpers.cdc"

access(all)
fun setup() {
    // Deploy FlowALPv0 and dependencies so the contract types are available.
    deployContracts()
}

// ============================================================================
// FixedCurve Tests
// ============================================================================

access(all)
fun test_FixedCurve_returns_constant_rate() {
    // Create a fixed rate curve with a 5% nominal yearly rate
    let fixedRate: UFix128 = 0.05
    let curve = FlowALPInterestRates.FixedCurve(yearlyRate: fixedRate)

    // Test with various credit and debit balances
    let rate1 = curve.interestRate(creditBalance: 100.0, debitBalance: 0.0)
    Test.assertEqual(fixedRate, rate1)

    let rate2 = curve.interestRate(creditBalance: 0.0, debitBalance: 100.0)
    Test.assertEqual(fixedRate, rate2)
}

access(all)
fun test_FixedCurve_accepts_zero_rate() {
    // Zero rate should be valid (0% nominal yearly rate)
    let curve = FlowALPInterestRates.FixedCurve(yearlyRate: 0.0)
    let rate = curve.interestRate(creditBalance: 100.0, debitBalance: 50.0)
    Test.assertEqual(0.0 as UFix128, rate)
}

// ============================================================================
// KinkCurve Tests
// ============================================================================
//
// For direct KinkCurve calls, `creditBalance` uses the same semantics as the
// live pool accounting: total supplied, i.e. total creditor claims for the
// token.
// It does NOT mean remaining idle liquidity in the pool.

access(all)
fun test_KinkCurve_at_zero_utilization() {
    // Create a kink curve with:
    // - 80% optimal utilization
    // - 1% base rate
    // - 4% slope1
    // - 60% slope2
    let curve = FlowALPInterestRates.KinkCurve(
        optimalUtilization: 0.80,
        baseRate: 0.01,
        slope1: 0.04,
        slope2: 0.60
    )

    // At 0% utilization (no debt), should return base rate
    let rate = curve.interestRate(creditBalance: 100.0, debitBalance: 0.0)
    Test.assertEqual(0.01 as UFix128, rate)
}

access(all)
fun test_KinkCurve_before_kink() {
    // Create a kink curve with:
    // - 80% optimal utilization (the kink)
    // - 1% base rate
    // - 4% slope1
    // - 60% slope2
    let curve = FlowALPInterestRates.KinkCurve(
        optimalUtilization: 0.80,
        baseRate: 0.01,
        slope1: 0.04,
        slope2: 0.60
    )

    // At 40% utilization (credit: 100 supplied, debit: 40 borrowed)
    // utilization = 40 / 100 = 0.40
    // utilizationFactor = 0.40 / 0.80 = 0.5
    // rate = 0.01 + (0.04 × 0.5) = 0.01 + 0.02 = 0.03
    let rate = curve.interestRate(creditBalance: 100.0, debitBalance: 40.0)
    Test.assertEqual(0.03 as UFix128, rate)
}

access(all)
fun test_KinkCurve_at_kink() {
    // Create a kink curve
    let curve = FlowALPInterestRates.KinkCurve(
        optimalUtilization: 0.80,
        baseRate: 0.01,
        slope1: 0.04,
        slope2: 0.60
    )

    // At 80% utilization (credit: 100 supplied, debit: 80 borrowed)
    // utilization = 80 / 100 = 0.80 (exactly at kink)
    // rate = 0.01 + 0.04 = 0.05
    let rate = curve.interestRate(creditBalance: 100.0, debitBalance: 80.0)
    Test.assertEqual(0.05 as UFix128, rate)
}

access(all)
fun test_KinkCurve_after_kink() {
    // Create a kink curve
    let curve = FlowALPInterestRates.KinkCurve(
        optimalUtilization: 0.80,
        baseRate: 0.01,
        slope1: 0.04,
        slope2: 0.60
    )

    // At 90% utilization (credit: 100 supplied, debit: 90 borrowed)
    // utilization = 90 / 100 = 0.90
    // excessUtilization = 0.90 - 0.80 = 0.10
    // maxExcess = 1.0 - 0.80 = 0.20
    // excessFactor = 0.10 / 0.20 = 0.5
    // rate = 0.01 + 0.04 + (0.60 × 0.5) = 0.01 + 0.04 + 0.30 = 0.35
    let rate = curve.interestRate(creditBalance: 100.0, debitBalance: 90.0)
    Test.assertEqual(0.35 as UFix128, rate)
}

access(all)
fun test_KinkCurve_at_full_utilization() {
    // Create a kink curve
    let curve = FlowALPInterestRates.KinkCurve(
        optimalUtilization: 0.80,
        baseRate: 0.01,
        slope1: 0.04,
        slope2: 0.60
    )

    // At 100% utilization (credit: 100 supplied, debit: 100 borrowed)
    // utilization = 100 / 100 = 1.0
    // excessUtilization = 1.0 - 0.80 = 0.20
    // maxExcess = 1.0 - 0.80 = 0.20
    // excessFactor = 0.20 / 0.20 = 1.0
    // rate = 0.01 + 0.04 + (0.60 × 1.0) = 0.65
    let rate = curve.interestRate(creditBalance: 100.0, debitBalance: 100.0)
    Test.assertEqual(0.65 as UFix128, rate)
}

access(all)
fun test_KinkCurve_zero_credit_balance_saturates_at_full_utilization() {
    let curve = FlowALPInterestRates.KinkCurve(
        optimalUtilization: 0.80,
        baseRate: 0.01,
        slope1: 0.04,
        slope2: 0.60
    )

    // Defensive edge case: if positive debt is ever observed with zero credit,
    // the curve should saturate at 100% utilization instead of dividing by zero.
    let rate = curve.interestRate(creditBalance: 0.0, debitBalance: 100.0)
    Test.assertEqual(0.65 as UFix128, rate)
}

// Validation tests are implicit in the preconditions - attempting to create invalid curves will panic
// The preconditions ensure:
// - optimalUtilization must be between 1% and 99%
// - slope2 >= slope1
// - baseRate + slope1 + slope2 <= 400%

// ============================================================================
// Integration Tests with TokenState
// ============================================================================

access(all)
fun test_TokenState_with_FixedCurve() {
    // Create a TokenState with a fixed rate curve
    let fixedCurve = FlowALPInterestRates.FixedCurve(yearlyRate: 0.10)
    var tokenState = FlowALPModels.TokenStateImplv1(
        tokenType: Type<@FlowToken.Vault>(),
        interestCurve: fixedCurve,
        depositRate: 1.0,
        depositCapacityCap: 1_000.0
    )

    // Set up some credit and debit balances
    // Note: Balance changes automatically trigger updateInterestRates() via updateForUtilizationChange()
    tokenState.increaseCreditBalance(by: 100.0)
    tokenState.increaseDebitBalance(by: 50.0)

    // Debit rate should be the per-second conversion of 10% yearly
    let expectedDebitRate = FlowALPMath.perSecondInterestRate(yearlyRate: 0.10)
    Test.assertEqual(expectedDebitRate, tokenState.getCurrentDebitRate())

    // For FixedCurve, credit rate uses the SPREAD MODEL:
    // creditRate = debitRate * (1 - protocolFeeRate)
    // where protocolFeeRate = insuranceRate + stabilityFeeRate
    // debitRate = 0.10
    // protocolFeeRate = 0.0 + 0.05 = 0.05 (default insuranceRate = 0.0, default stabilityFeeRate = 0.05)
    // creditYearly = 0.10 * (1 - 0.05) = 0.095
    let expectedCreditRate = FlowALPMath.perSecondInterestRate(yearlyRate: 0.095)
    Test.assertEqual(expectedCreditRate, tokenState.getCurrentCreditRate())
}

access(all)
fun test_TokenState_with_KinkCurve() {
    // Create a TokenState with a kink curve
    let kinkCurve = FlowALPInterestRates.KinkCurve(
        optimalUtilization: 0.80,
        baseRate: 0.02,
        slope1: 0.05,
        slope2: 0.50
    )
    var tokenState = FlowALPModels.TokenStateImplv1(
        tokenType: Type<@FlowToken.Vault>(),
        interestCurve: kinkCurve,
        depositRate: 1.0,
        depositCapacityCap: 1_000.0
    )

    // Set up balances for 60% utilization (below kink)
    // credit: 100 supplied, debit: 60 borrowed
    // utilization = 0.60
    // rate = 0.02 + (0.05 × 0.60 / 0.80) = 0.02 + 0.0375 = 0.0575
    // Note: Balance changes automatically trigger updateInterestRates() via updateForUtilizationChange()
    tokenState.increaseCreditBalance(by: 100.0)
    tokenState.increaseDebitBalance(by: 60.0)

    // Verify the debit rate
    let expectedYearlyRate: UFix128 = 0.0575
    let expectedDebitRate = FlowALPMath.perSecondInterestRate(yearlyRate: expectedYearlyRate)
    Test.assertEqual(expectedDebitRate, tokenState.getCurrentDebitRate())
}

access(all)
fun test_KinkCurve_rates_update_automatically_on_balance_change() {
    // Create TokenState with KinkCurve (80% optimal, 2% base, 5% slope1, 50% slope2)
    let kinkCurve = FlowALPInterestRates.KinkCurve(
        optimalUtilization: 0.80,
        baseRate: 0.02,
        slope1: 0.05,
        slope2: 0.50
    )
    var tokenState = FlowALPModels.TokenStateImplv1(
        tokenType: Type<@FlowToken.Vault>(),
        interestCurve: kinkCurve,
        depositRate: 1.0,
        depositCapacityCap: 1_000.0
    )

    // Step 1: Add initial balances - rates should auto-update via updateForUtilizationChange()
    // credit: 100, debit: 0 → utilization = 0% → rate = baseRate = 2%
    tokenState.increaseCreditBalance(by: 100.0)

    let rateAtZeroUtilization = FlowALPMath.perSecondInterestRate(yearlyRate: 0.02)
    Test.assertEqual(rateAtZeroUtilization, tokenState.getCurrentDebitRate())

    // Step 2: Add debt to create 50% utilization
    // credit: 100 supplied, debit: 50 borrowed → utilization = 50/100 = 50%
    // rate = 0.02 + (0.05 × 0.50 / 0.80) = 0.02 + 0.03125 = 0.05125
    tokenState.increaseDebitBalance(by: 50.0)

    let rateAt50Utilization = FlowALPMath.perSecondInterestRate(yearlyRate: 0.05125)
    Test.assertEqual(rateAt50Utilization, tokenState.getCurrentDebitRate())

    // Step 3: Increase utilization to 90% (above kink)
    // credit: 100 supplied, debit: 90 borrowed → utilization = 90/100 = 90%
    // excessUtil = (0.90 - 0.80) / (1 - 0.80) = 0.50
    // rate = 0.02 + 0.05 + (0.50 × 0.50) = 0.32
    tokenState.increaseDebitBalance(by: 40.0)

    let rateAt90Util = FlowALPMath.perSecondInterestRate(yearlyRate: 0.32)
    Test.assertEqual(rateAt90Util, tokenState.getCurrentDebitRate())

    // Step 4: Decrease debt to lower utilization back to 0%
    // credit: 100, debit: 0 → utilization = 0% → rate = baseRate = 2%
    tokenState.decreaseDebitBalance(by: 90.0)

    let rateBackToZero = FlowALPMath.perSecondInterestRate(yearlyRate: 0.02)
    Test.assertEqual(rateBackToZero, tokenState.getCurrentDebitRate())
}

// ============================================================================
// Edge Cases
// ============================================================================

access(all)
fun test_KinkCurve_with_very_small_balances() {
    let curve = FlowALPInterestRates.KinkCurve(
        optimalUtilization: 0.80,
        baseRate: 0.01,
        slope1: 0.04,
        slope2: 0.60
    )

    // Test with very small balances (fractional tokens)
    let rate = curve.interestRate(creditBalance: 0.02, debitBalance: 0.01)
    // At 50% utilization, rate should be: 0.01 + (0.04 × 0.50 / 0.80) = 0.01 + 0.025 = 0.035
    Test.assertEqual(0.035 as UFix128, rate)
}

access(all)
fun test_KinkCurve_with_large_balances() {
    let curve = FlowALPInterestRates.KinkCurve(
        optimalUtilization: 0.80,
        baseRate: 0.01,
        slope1: 0.04,
        slope2: 0.60
    )

    // Test with large balances (millions of tokens)
    let rate = curve.interestRate(creditBalance: 10_000_000.0, debitBalance: 5_000_000.0)
    // At 50% utilization, rate should be: 0.01 + (0.04 × 0.50 / 0.80) = 0.035
    Test.assertEqual(0.035 as UFix128, rate)
}

// ============================================================================
// Precondition Failure Tests
// ============================================================================
// These tests verify that invalid parameters are rejected by the preconditions

access(all)
fun test_FixedCurve_rejects_rate_exceeding_max() {
    // Attempt to create a fixed rate curve with rate > 100%
    // This should fail the precondition: yearlyRate <= 1.0
    let res = _executeScript("./scripts/test_fixed_rate_max.cdc", [])
    Test.expect(res, Test.beFailed())
}

access(all)
fun test_KinkCurve_rejects_optimal_too_low() {
    // Attempt to create a kink curve with optimalUtilization < 1%
    // This should fail the precondition: optimalUtilization >= 0.01
    let res = _executeScript("./scripts/test_kink_optimal_too_low.cdc", [])
    Test.expect(res, Test.beFailed())
}

access(all)
fun test_KinkCurve_rejects_optimal_too_high() {
    // Attempt to create a kink curve with optimalUtilization > 99%
    // This should fail the precondition: optimalUtilization <= 0.99
    let res = _executeScript("./scripts/test_kink_optimal_too_high.cdc", [])
    Test.expect(res, Test.beFailed())
}

access(all)
fun test_KinkCurve_rejects_slope2_less_than_slope1() {
    // Attempt to create a kink curve with slope2 < slope1
    // This should fail the precondition: slope2 >= slope1
    let res = _executeScript("./scripts/test_kink_slope2_less_than_slope1.cdc", [])
    Test.expect(res, Test.beFailed())
}

access(all)
fun test_KinkCurve_rejects_max_rate_exceeded() {
    // Attempt to create a kink curve with baseRate + slope1 + slope2 > 400%
    // This should fail the precondition: baseRate + slope1 + slope2 <= 4.0
    let res = _executeScript("./scripts/test_kink_max_rate.cdc", [])
    Test.expect(res, Test.beFailed())
}
