import Test
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
    // For FixedRateInterestCurve, credit rate = debit rate - insurance rate (simple spread)
    let debitRate: UFix128 = 0.10  // 10% yearly
    var tokenState = FlowCreditMarket.TokenState(
        interestCurve: FlowCreditMarket.FixedRateInterestCurve(yearlyRate: debitRate),
        depositRate: 1.0,
        depositCapacityCap: 1_000.0
    )
    // Balance changes automatically trigger updateInterestRates() via updateForUtilizationChange()
    tokenState.increaseCreditBalance(by: 1000.0)
    tokenState.increaseDebitBalance(by: 500.0)  // 50% utilization

    // Debit rate should match the fixed yearly rate
    let expectedDebitRate = FlowCreditMarket.perSecondInterestRate(yearlyRate: debitRate)
    Test.assertEqual(expectedDebitRate, tokenState.currentDebitRate)

    // Credit rate = debitRate - insuranceRate (spread model, independent of utilization)
    let insuranceRate: UFix128 = FlowCreditMarketMath.toUFix128(tokenState.insuranceRate)
    let expectedCreditYearly = debitRate - insuranceRate  // 0.10 - 0.001 = 0.099
    let expectedCreditRate = FlowCreditMarket.perSecondInterestRate(yearlyRate: expectedCreditYearly)
    Test.assertEqual(expectedCreditRate, tokenState.currentCreditRate)
}

access(all)
fun test_FixedRateInterestCurve_zero_credit_rate_when_insurance_exceeds_debit() {
    // When insuranceRate >= debitRate, credit rate should be 0
    let debitRate: UFix128 = 0.001  // 0.1% yearly (same as default insurance)
    var tokenState = FlowCreditMarket.TokenState(
        interestCurve: FlowCreditMarket.FixedRateInterestCurve(yearlyRate: debitRate),
        depositRate: 1.0,
        depositCapacityCap: 1_000.0
    )
    // Balance changes automatically trigger rate updates via updateForUtilizationChange()
    tokenState.increaseCreditBalance(by: 100.0)
    tokenState.increaseDebitBalance(by: 50.0)

    // Debit rate still follows the curve
    let expectedDebitRate = FlowCreditMarket.perSecondInterestRate(yearlyRate: debitRate)
    Test.assertEqual(expectedDebitRate, tokenState.currentDebitRate)

    // Credit rate should be `one` (multiplicative identity = 0% growth) since insurance >= debit rate
    Test.assertEqual(FlowCreditMarketMath.one, tokenState.currentCreditRate)
}

// =============================================================================
// KinkInterestCurve Tests (Reserve Factor Model: insurance = % of income)
// =============================================================================

access(all)
fun test_KinkCurve_uses_reserve_factor_model() {
    // For non-FixedRate curves, insurance is a percentage of debit income
    let debitRate: UFix128 = 0.20  // 20% yearly
    var tokenState = FlowCreditMarket.TokenState(
        interestCurve: CustomFixedCurve(debitRate),  // Custom curve triggers reserve factor path
        depositRate: 1.0,
        depositCapacityCap: 1_000.0
    )
    // Balance changes automatically trigger rate updates via updateForUtilizationChange()
    tokenState.increaseCreditBalance(by: 200.0)
    tokenState.increaseDebitBalance(by: 50.0)  // 25% utilization

    // Debit rate should match the curve rate
    let expectedDebitRate = FlowCreditMarket.perSecondInterestRate(yearlyRate: debitRate)
    Test.assertEqual(expectedDebitRate, tokenState.currentDebitRate)

    // Credit rate = (debitIncome - debitIncome * insuranceRate) / creditBalance
    let debitIncome: UFix128 = tokenState.totalDebitBalance * debitRate  // 50 * 0.20 = 10
    let reserveFactor: UFix128 = FlowCreditMarketMath.toUFix128(tokenState.insuranceRate)
    let insurance: UFix128 = debitIncome * reserveFactor  // 10 * 0.001 = 0.01
    let expectedCreditYearly = (debitIncome - insurance) / tokenState.totalCreditBalance  // (10 - 0.01) / 200
    let expectedCreditRate = FlowCreditMarket.perSecondInterestRate(yearlyRate: expectedCreditYearly)
    Test.assertEqual(expectedCreditRate, tokenState.currentCreditRate)
}

access(all)
fun test_KinkCurve_zero_credit_rate_when_no_borrowing() {
    // When there's no debit balance, credit rate should be 0 (no income to distribute)
    let debitRate: UFix128 = 0.10
    var tokenState = FlowCreditMarket.TokenState(
        interestCurve: CustomFixedCurve(debitRate),
        depositRate: 1.0,
        depositCapacityCap: 1_000.0
    )
    // Balance changes automatically trigger rate updates via updateForUtilizationChange()
    tokenState.increaseCreditBalance(by: 100.0)
    // No debit balance - zero utilization

    // Debit rate still follows the curve
    let expectedDebitRate = FlowCreditMarket.perSecondInterestRate(yearlyRate: debitRate)
    Test.assertEqual(expectedDebitRate, tokenState.currentDebitRate)

    // Credit rate should be `one` (multiplicative identity = 0% growth) since no debit income to distribute
    Test.assertEqual(FlowCreditMarketMath.one, tokenState.currentCreditRate)
}
