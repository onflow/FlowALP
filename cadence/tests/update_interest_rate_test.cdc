import Test
import "FlowCreditMarket"
import "FlowCreditMarketMath"
import "test_helpers.cdc"

access(all) struct FixedInterestCurve: FlowCreditMarket.InterestCurve {
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

access(all)
fun test_updateInterestRates_applies_income_minus_insurance_to_credit_rate() {
    // Configure a token state with known balances and a fixed debit rate.
    let debitRate: UFix128 = 0.20 as UFix128
    var tokenState = FlowCreditMarket.TokenState(
        interestCurve: FixedInterestCurve(debitRate),
        depositRate: 1.0,
        depositCapacityCap: 1_000.0
    )
    tokenState.increaseCreditBalance(by: 200.0 as UFix128)
    tokenState.increaseDebitBalance(by: 50.0 as UFix128)

    tokenState.updateInterestRates()

    // Debit rate should match the per-second conversion of the fixed yearly rate.
    let expectedDebitRate = FlowCreditMarket.perSecondInterestRate(yearlyRate: debitRate)
    Test.assertEqual(expectedDebitRate, tokenState.currentDebitRate)

    // Credit rate should derive from net debit income after insurance.
    let debitIncome: UFix128 = tokenState.totalDebitBalance * debitRate
    let insurance: UFix128 = tokenState.totalCreditBalance * UFix128(tokenState.insuranceRate)
    let expectedCreditYearly = (debitIncome - insurance) / tokenState.totalCreditBalance
    let expectedCreditRate = FlowCreditMarket.perSecondInterestRate(yearlyRate: expectedCreditYearly)
    Test.assertEqual(expectedCreditRate, tokenState.currentCreditRate)
}

access(all)
fun test_updateInterestRates_sets_zero_credit_rate_when_insufficient_income() {
    // Configure a token state where debit income cannot cover insurance.
    let debitRate: UFix128 = 0.001 as UFix128
    var tokenState = FlowCreditMarket.TokenState(
        interestCurve: FixedInterestCurve(debitRate),
        depositRate: 1.0,
        depositCapacityCap: 1_000.0
    )
    tokenState.increaseCreditBalance(by: 100.0 as UFix128)
    tokenState.increaseDebitBalance(by: 1.0 as UFix128)

    tokenState.updateInterestRates()

    // Debit rate still follows the curve, but credit rate should fall back to 0% (per-second factor of 1).
    let expectedDebitRate = FlowCreditMarket.perSecondInterestRate(yearlyRate: debitRate)
    Test.assertEqual(expectedDebitRate, tokenState.currentDebitRate)
    Test.assertEqual(1.0 as UFix128, tokenState.currentCreditRate)
}

