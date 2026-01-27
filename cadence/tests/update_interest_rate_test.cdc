import Test
import "MOET"
import "FlowCreditMarket"
import "FlowCreditMarketMath"
import "test_helpers.cdc"

// Custom curve for testing reserve factor path (NOT FlowCreditMarket.FixedRateInterestCurve)
// This will trigger the KinkCurve/reserve factor calculation path
access(all) struct CustomFixedCurve: FlowCreditMarket.InterestCurve {
    access(all) let rate: UFix128

    init(_ rate: UFix128) {
        self.rate = rate
    }

    access(all) fun interestRate(creditBalance: UFix128, debitBalance: UFix128): UFix128 {
        return self.rate
    }
}

access(all)
fun setup() {
    // Deploy FlowCreditMarket and dependencies so the contract types are available.
    deployContracts()
}

// =============================================================================
// FixedRateInterestCurve Tests (Spread Model: creditRate = debitRate - insuranceRate)
// =============================================================================

access(all)
fun test_FixedRateInterestCurve_uses_spread_model() {
    // For FixedRateInterestCurve, credit rate = debit rate * (1 - protocolFeeRate)
    // where protocolFeeRate = insuranceRate + stabilityFeeRate
    let debitRate: UFix128 = 0.10  // 10% yearly
    var tokenState = FlowCreditMarket.TokenState(
        tokenType: Type<@MOET.Vault>(),
        interestCurve: FlowCreditMarket.FixedRateInterestCurve(yearlyRate: debitRate),
        depositRate: 1.0,
        depositCapacityCap: 1_000.0
    )
    // set insurance rate
    tokenState.setInsuranceRate(0.001)
    // set stability fee rate to 0 for this test to isolate insurance rate effect
    tokenState.setStabilityFeeRate(0.0)
    // Balance changes automatically trigger updateInterestRates() via updateForUtilizationChange()
    tokenState.increaseCreditBalance(by: 1000.0)
    tokenState.increaseDebitBalance(by: 500.0)  // 50% utilization

    // Debit rate should match the fixed yearly rate
    let expectedDebitRate = FlowCreditMarket.perSecondInterestRate(yearlyRate: debitRate)
    Test.assertEqual(expectedDebitRate, tokenState.currentDebitRate)

    // Credit rate = debitRate * (1 - protocolFeeRate) where protocolFeeRate = insuranceRate + stabilityFeeRate
    let expectedCreditYearly = UFix128(0.0999)  // 0.10 * (1 - 0.001)
    let expectedCreditRate = FlowCreditMarket.perSecondInterestRate(yearlyRate: expectedCreditYearly)
    Test.assertEqual(expectedCreditRate, tokenState.currentCreditRate)
}

// =============================================================================
// KinkInterestCurve Tests (Reserve Factor Model: insurance = % of income)
// =============================================================================

access(all)
fun test_KinkCurve_uses_reserve_factor_model() {
    // For non-FixedRate curves, protocol fee is a percentage of debit income
    // protocolFeeRate = insuranceRate + stabilityFeeRate
    let debitRate: UFix128 = 0.20  // 20% yearly
    var tokenState = FlowCreditMarket.TokenState(
        tokenType: Type<@MOET.Vault>(),
        interestCurve: CustomFixedCurve(debitRate),  // Custom curve triggers reserve factor path
        depositRate: 1.0,
        depositCapacityCap: 1_000.0
    )
    // set insurance rate (default stabilityFeeRate = 0.05)
    tokenState.setInsuranceRate(0.001)
    // Balance changes automatically trigger rate updates via updateForUtilizationChange()
    tokenState.increaseCreditBalance(by: 200.0)
    tokenState.increaseDebitBalance(by: 50.0)  // 25% utilization

    // Debit rate should match the curve rate
    let expectedDebitRate = FlowCreditMarket.perSecondInterestRate(yearlyRate: debitRate)
    Test.assertEqual(expectedDebitRate, tokenState.currentDebitRate)

    // Credit rate = (debitIncome - protocolFeeAmount) / creditBalance
    // where protocolFeeAmount = debitIncome * protocolFeeRate
    // debitIncome = 50 * 0.20 = 10
    // protocolFeeRate = insuranceRate + stabilityFeeRate = 0.001 + 0.05 = 0.051
    // protocolFeeAmount = 10 * 0.051 = 0.51
    // creditYearly = (10 - 0.51) / 200 = 0.04745
    let expectedCreditRate =  FlowCreditMarket.perSecondInterestRate(yearlyRate: 0.04745)
    Test.assertEqual(expectedCreditRate, tokenState.currentCreditRate)
}

access(all)
fun test_KinkCurve_zero_credit_rate_when_no_borrowing() {
    // When there's no debit balance, credit rate should be 0 (no income to distribute)
    let debitRate: UFix128 = 0.10
    var tokenState = FlowCreditMarket.TokenState(
        tokenType: Type<@MOET.Vault>(),
        interestCurve: CustomFixedCurve(debitRate),
        depositRate: 1.0,
        depositCapacityCap: 1_000.0
    )
    // set insurance rate
    tokenState.setInsuranceRate(0.001)
    // Balance changes automatically trigger rate updates via updateForUtilizationChange()
    tokenState.increaseCreditBalance(by: 100.0)
    // No debit balance - zero utilization

    // Debit rate still follows the curve
    let expectedDebitRate = FlowCreditMarket.perSecondInterestRate(yearlyRate: debitRate)
    Test.assertEqual(expectedDebitRate, tokenState.currentDebitRate)

    // Credit rate should be `one` (multiplicative identity = 0% growth) since no debit income to distribute
    Test.assertEqual(FlowCreditMarketMath.one, tokenState.currentCreditRate)
}
