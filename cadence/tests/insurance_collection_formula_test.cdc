import Test
import BlockchainHelpers

import "MOET"
import "FlowToken"
import "test_helpers.cdc"


access(all)
fun setup() {
    deployContracts()
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)

    // Add FlowToken as a supported collateral type (needed for borrowing scenarios)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )
}

// -----------------------------------------------------------------------------
// Test: collectInsurance full success flow with formula verification
// Full flow: LP deposits to create credit → borrower borrows to create debit
// → advance time → collect insurance → verify MOET returned, reserves reduced,
// timestamp updated, and formula
// Formula: insuranceAmount = totalDebitBalance * insuranceRate * (timeElapsed / secondsPerYear)
//
// This test runs in isolation (separate file) to ensure totalDebitBalance
// equals exactly the borrowed amount without interference from other tests.
// -----------------------------------------------------------------------------
access(all)
fun test_collectInsurance_success_fullAmount() {
    // setup LP to provide MOET liquidity for borrowing
    let lp = Test.createAccount()
    setupMoetVault(lp, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: lp.address, amount: 10000.0, beFailed: false)

    // LP deposits MOET (creates credit balance, provides borrowing liquidity)
    createPosition(admin: PROTOCOL_ACCOUNT, signer: lp, amount: 10000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    // setup borrower with FLOW collateral
    // With 0.8 CF and 1.3 target health: 15000 FLOW collateral allows borrowing ~9231 MOET
    // borrow = (collateral * price * CF) / targetHealth = (15000 * 1.0 * 0.8) / 1.3 ≈ 9230.77
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    transferFlowTokens(to: borrower, amount: 15000.0)

    // borrower deposits 15000 FLOW and auto-borrows MOET (creates debit balance ~9231 MOET)
    createPosition(admin: PROTOCOL_ACCOUNT, signer: borrower, amount: 15000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: true)

    // setup protocol account with MOET vault for the swapper
    setupMoetVault(PROTOCOL_ACCOUNT, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: PROTOCOL_ACCOUNT.address, amount: 10000.0, beFailed: false)

    // configure insurance swapper (1:1 ratio)
    let swapperResult = setInsuranceSwapper(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, priceRatio: 1.0)
    Test.expect(swapperResult, Test.beSucceeded())

    // set 10% annual debit rate; credit rate = 0.1 × (1 − 0.15) = 0.085
    setInterestCurveFixed(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, yearlyRate: 0.1)

    // set insurance rate (10% of debit income)
    let rateResult = setInsuranceRate(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, insuranceRate: 0.1)
    Test.expect(rateResult, Test.beSucceeded())

    // collect insurance to reset last insurance collection timestamp,
    // this accounts for timing variation between pool creation and this point
    // (each transaction/script execution advances the block timestamp slightly)
    collectInsurance(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)

    // record balances after resetting the timestamp
    let initialInsuranceBalance = getInsuranceFundBalance()
    let reserveBalanceBefore = getReserveBalance(vaultIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.assert(reserveBalanceBefore > 0.0, message: "Reserves should exist after deposit")

    // record timestamp before advancing time
    let timestampBefore = getBlockTimestamp()
    Test.moveTime(by: ONE_YEAR)

    collectInsurance(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)

    // verify insurance was collected, reserves decreased
    let finalInsuranceBalance = getInsuranceFundBalance()
    let reserveBalanceAfter = getReserveBalance(vaultIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.assert(reserveBalanceAfter < reserveBalanceBefore, message: "Reserves should have decreased after collection")

    let collectedInsuranceAmount = finalInsuranceBalance - initialInsuranceBalance

    // collectProtocolFees withdraws both insurance AND stability in one call.
    // With insuranceRate=0.1 and stabilityFeeRate=0.05 (default), both are withdrawn.
    let stabilityFundBalance = getStabilityFundBalance(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER) ?? 0.0
    let amountWithdrawnFromReserves = reserveBalanceBefore - reserveBalanceAfter
    // Total withdrawn = insurance (→ fund via swap with 1:1 ratio) + stability (kept as MOET)
    Test.assertEqual(amountWithdrawnFromReserves, collectedInsuranceAmount + stabilityFundBalance)

    // verify last insurance collection time was updated to current block timestamp
    let currentTimestamp = getBlockTimestamp()
    let lastInsuranceCollectionTime = getLastInsuranceCollectionTime(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.assertEqual(currentTimestamp, lastInsuranceCollectionTime!)

    // verify formula (index-based, accounts for credit offset):
    //   protocolFee = debitIncome - creditIncome
    //   insuranceAmount = protocolFee × insuranceRate / totalProtocolFeeRate
    //
    //   debitBalance  ≈ 15000 × 0.8 / 1.3 ≈ 9230.77 MOET
    //   creditBalance = 10000 MOET
    //   debitGrowth   = e^0.1 ≈ 1.10517091807  (e^rate ≈ (1 + rate/N)^N for big N)
    //   creditGrowth  = e^(0.085) ≈ 1.0887170667   (creditRate = debitRate × (1 − 0.15) = 0.085)
    //   debitIncome   = 9230.77 × 0.10517091807 ≈ 970.808555393
    //   creditIncome  = 10000  × 0.0887170667 ≈ 887.170667
    //   protocolFee   = 970.808555393 - 887.170667 = 83.637888393 MOET
    //   insuranceAmt  = 83.637888393 × 0.1 / 0.15 ≈ 55.758 MOET
    //
    let expectedCollectedAmount = 55.758

    Test.assert(equalWithinVariance(expectedCollectedAmount, collectedInsuranceAmount, 0.001), message: "Insurance collected should be around \(expectedCollectedAmount) but current \(collectedInsuranceAmount)")
}
