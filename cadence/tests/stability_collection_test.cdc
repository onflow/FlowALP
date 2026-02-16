import Test
import BlockchainHelpers

import "MOET"
import "FlowToken"
import "test_helpers.cdc"

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()

    // Add FlowToken as a supported collateral type (needed for borrowing scenarios)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: MOET_TOKEN_IDENTIFIER, price: 1.0)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)

    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // take snapshot first, then advance time so reset() target is always lower than current height
    snapshot = getCurrentBlockHeight()
    // move time by 1 second so Test.reset() works properly before each test
    Test.moveTime(by: 1.0)
}

access(all)
fun beforeEach() {
    Test.reset(to: snapshot)
}

// -----------------------------------------------------------------------------
// Test: collectStability when no deposits have been made (no debit balance)
// When no borrowing has occurred, there's no interest income and no stability to collect
// -----------------------------------------------------------------------------
access(all)
fun test_collectStability_zeroDebitBalance_returnsNil() {
    // setup user with deposit but no borrowing (no debit balance = no interest income)
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: user.address, amount: 10000.0, beFailed: false)

    // set stability fee rate
    let rateResult = setStabilityFeeRate(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, stabilityFeeRate: 0.1)
    Test.expect(rateResult, Test.beSucceeded())

    // verify initial stability fund balance is 0
    let initialBalance = getStabilityFundBalance(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.assertEqual(nil, initialBalance)

    Test.moveTime(by: DAY)

    // collect stability - should return nil since no debit balance = no interest income
    let res= collectStability(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.expect(res, Test.beSucceeded())

    // verify stability fund balance is still nil (no collection occurred)
    let finalBalance = getStabilityFundBalance(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.assertEqual(nil, finalBalance)
}

// -----------------------------------------------------------------------------
// Test: collectStability only collects up to available reserve balance
// When calculated stability amount exceeds reserve balance, it collects
// only what is available. Verify exact amount withdrawn from reserves.
// -----------------------------------------------------------------------------
access(all)
fun test_collectStability_partialReserves_collectsAvailable() {
    // setup LP to provide MOET liquidity for borrowing (small amount to create limited reserves)
    let lp = Test.createAccount()
    setupMoetVault(lp, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: lp.address, amount: 1000.0, beFailed: false)

    // LP deposits 1000 MOET (creates credit balance, provides borrowing liquidity)
    createPosition(admin: PROTOCOL_ACCOUNT, signer: lp, amount: 1000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    // setup borrower with large FLOW collateral to borrow most of the MOET
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    transferFlowTokens(to: borrower, amount: 10000.0)

    // borrower deposits 10000 FLOW and auto-borrows MOET
    // With 0.8 CF and 1.3 target health: 10000 FLOW allows borrowing ~6153 MOET
    // But pool only has 1000 MOET, so borrower gets ~1000 MOET (limited by liquidity)
    // This leaves reserves very low (close to 0)
    createPosition(admin: PROTOCOL_ACCOUNT, signer: borrower, amount: 10000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: true)

    setupMoetVault(PROTOCOL_ACCOUNT, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: PROTOCOL_ACCOUNT.address, amount: 10000.0, beFailed: false)

    // set 90% annual debit rate
    setInterestCurveFixed(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, yearlyRate: 0.9)

    // set a high stability fee rate so calculated amount would exceed reserves
    // Note: stabilityFeeRate must be < 1.0, using 0.9 which combined with default insuranceRate (0.0) = 0.9 < 1.0
    let rateResult = setStabilityFeeRate(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, stabilityFeeRate: 0.9)
    Test.expect(rateResult, Test.beSucceeded())

    let initialStabilityBalance = getStabilityFundBalance(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.assertEqual(nil, initialStabilityBalance)

    Test.moveTime(by: ONE_YEAR + DAY * 30.0) // 1 year + 1 month

    // collect stability - should collect up to available reserve balance
    let res = collectStability(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.expect(res, Test.beSucceeded())

    let finalStabilityBalance = getStabilityFundBalance(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    let reserveBalanceAfter = getReserveBalance(vaultIdentifier: MOET_TOKEN_IDENTIFIER)

    // stability fund balance should equal amount withdrawn from reserves
    Test.assertEqual(0.0, reserveBalanceAfter)

    // verify collection was limited by reserves
    // Formula: 90% debit income -> 90% stability rate -> large amount, but limited by available reserves
    Test.assertEqual(1000.0, finalStabilityBalance!)
}

// -----------------------------------------------------------------------------
// Test: collectStability when calculated amount rounds to zero returns nil
// Very small time elapsed + small debit balance can result in stabilityAmountUFix64 == 0
// Should return nil and update the last stability collection timestamp
// -----------------------------------------------------------------------------
access(all)
fun test_collectStability_tinyAmount_roundsToZero_returnsNil() {
    // setup LP with deposit
    let lp = Test.createAccount()
    setupMoetVault(lp, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: lp.address, amount: 100.0, beFailed: false)

    // LP deposits small amount
    createPosition(admin: PROTOCOL_ACCOUNT, signer: lp, amount: 100.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    // setup borrower with tiny borrow
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    transferFlowTokens(to: borrower, amount: 1.0)

    // borrower deposits small FLOW and borrows tiny amount of MOET
    createPosition(admin: PROTOCOL_ACCOUNT, signer: borrower, amount: 1.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: true)

    // set a very low stability fee rate
    let rateResult = setStabilityFeeRate(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, stabilityFeeRate: 0.0001) // 0.01%
    Test.expect(rateResult, Test.beSucceeded())

    let initialBalance = getStabilityFundBalance(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.assertEqual(nil, initialBalance)

    // move time by just 1 second - with tiny debit and low rate, amount should round to 0
    Test.moveTime(by: 1.0)

    // collect stability - calculated amount should be ~0 due to tiny balance * low rate * short time
    let res = collectStability(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.expect(res, Test.beSucceeded())

    // verify stability fund balance is still nil (amount rounded to 0, no collection)
    let finalBalance = getStabilityFundBalance(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.assertEqual(nil, finalBalance)
}

// -----------------------------------------------------------------------------
// Test: collectStability with multiple token types
// Verifies that stability collection works independently for different tokens
// Each token type has its own last stability collection timestamp and rate
// -----------------------------------------------------------------------------
access(all)
fun test_collectStability_multipleTokens() {
    // Note: FlowToken is already added in setup()

    // setup MOET LP to provide MOET liquidity for borrowing
    let moetLp = Test.createAccount()
    setupMoetVault(moetLp, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: moetLp.address, amount: 10000.0, beFailed: false)

    // MOET LP deposits MOET (creates MOET credit balance)
    createPosition(admin: PROTOCOL_ACCOUNT, signer: moetLp, amount: 10000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    // setup FLOW LP to provide FLOW liquidity for borrowing
    let flowLp = Test.createAccount()
    setupMoetVault(flowLp, beFailed: false)
    transferFlowTokens(to: flowLp, amount: 10000.0)

    // FLOW LP deposits FLOW (creates FLOW credit balance)
    createPosition(admin: PROTOCOL_ACCOUNT, signer: flowLp, amount: 10000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    // setup MOET borrower with FLOW collateral (creates MOET debit)
    let moetBorrower = Test.createAccount()
    setupMoetVault(moetBorrower, beFailed: false)
    transferFlowTokens(to: moetBorrower, amount: 1000.0)

    // MOET borrower deposits FLOW and auto-borrows MOET (creates MOET debit balance)
    createPosition(admin: PROTOCOL_ACCOUNT, signer: moetBorrower, amount: 1000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: true)

    // setup FLOW borrower with MOET collateral (creates FLOW debit)
    let flowBorrower = Test.createAccount()
    setupMoetVault(flowBorrower, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: flowBorrower.address, amount: 1000.0, beFailed: false)

    // FLOW borrower deposits MOET as collateral
    createPosition(admin: PROTOCOL_ACCOUNT, signer: flowBorrower, amount: 1000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    // Then borrow FLOW (creates FLOW debit balance)
    borrowFromPosition(signer: flowBorrower, positionId: 3, tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER, amount: 500.0, beFailed: false)

    // set 10% annual debit rates
    // Stability is calculated on interest income, not debit balance directly
    setInterestCurveFixed(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, yearlyRate: 0.1)
    setInterestCurveFixed(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER, yearlyRate: 0.1)

    // set different stability fee rates for each token type (percentage of interest income)
    let moetRateResult = setStabilityFeeRate(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, stabilityFeeRate: 0.1) // 10%
    Test.expect(moetRateResult, Test.beSucceeded())

    let flowRateResult = setStabilityFeeRate(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER, stabilityFeeRate: 0.05) // 5%
    Test.expect(flowRateResult, Test.beSucceeded())

    // verify initial state
    let initialMoetStabilityBalance = getStabilityFundBalance(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.assertEqual(nil, initialMoetStabilityBalance)
    let initialFlowStabilityBalance = getStabilityFundBalance(tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER)
    Test.assertEqual(nil, initialFlowStabilityBalance)

    let moetReservesBefore = getReserveBalance(vaultIdentifier: MOET_TOKEN_IDENTIFIER)
    let flowReservesBefore = getReserveBalance(vaultIdentifier: FLOW_TOKEN_IDENTIFIER)
    Test.assert(moetReservesBefore > 0.0, message: "MOET reserves should exist after deposit")
    Test.assert(flowReservesBefore > 0.0, message: "Flow reserves should exist after deposit")

    // advance time
    Test.moveTime(by: ONE_YEAR)

    // collect stability for MOET only
    var res = collectStability(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.expect(res, Test.beSucceeded())

    let balanceAfterMoetCollection = getStabilityFundBalance(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.assert(balanceAfterMoetCollection! > 0.0, message: "MOET stability fund should have received tokens after MOET collection")

    // verify the amount withdrawn from MOET reserves equals the stability fund balance increase
    let moetAmountWithdrawn = moetReservesBefore - getReserveBalance(vaultIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.assertEqual(moetAmountWithdrawn, balanceAfterMoetCollection!)

    let moetLastCollectionTime = getLastStabilityCollectionTime(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    let flowLastCollectionTimeBeforeFlowCollection = getLastStabilityCollectionTime(tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER)

    // MOET timestamp should be updated, Flow timestamp should still be at pool creation time
    Test.assert(moetLastCollectionTime != nil, message: "MOET lastStabilityCollectionTime should be set")
    Test.assert(flowLastCollectionTimeBeforeFlowCollection != nil, message: "Flow lastStabilityCollectionTime should be set")
    Test.assert(moetLastCollectionTime! > flowLastCollectionTimeBeforeFlowCollection!, message: "MOET timestamp should be newer than Flow timestamp")

    // collect stability for Flow
    res = collectStability(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER)
    Test.expect(res, Test.beSucceeded())

    let flowBalanceAfterCollection = getStabilityFundBalance(tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER)
    Test.assert(flowBalanceAfterCollection! > 0.0, message: "Flow stability fund should have received tokens after Flow collection")

    let flowLastCollectionTimeAfter = getLastStabilityCollectionTime(tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER)
    Test.assert(flowLastCollectionTimeAfter != nil, message: "Flow lastStabilityCollectionTime should be set after collection")

    // verify reserves decreased for both token types
    let moetReservesAfter = getReserveBalance(vaultIdentifier: MOET_TOKEN_IDENTIFIER)
    let flowReservesAfter = getReserveBalance(vaultIdentifier: FLOW_TOKEN_IDENTIFIER)
    Test.assert(moetReservesAfter < moetReservesBefore, message: "MOET reserves should have decreased")
    Test.assert(flowReservesAfter < flowReservesBefore, message: "Flow reserves should have decreased")

    // verify the amount withdrawn from Flow reserves equals the Flow stability fund balance
    let flowAmountWithdrawn = flowReservesBefore - flowReservesAfter
    Test.assertEqual(flowAmountWithdrawn, flowBalanceAfterCollection!)

    // verify Flow timestamp is now updated (should be >= MOET timestamp since it was collected after)
    Test.assert(flowLastCollectionTimeAfter! >= moetLastCollectionTime!, message: "Flow timestamp should be >= MOET timestamp")
}

// -----------------------------------------------------------------------------
// Test: collectStability when stabilityFeeRate is 0.0 returns nil
// When the stability fee rate is set to 0, no collection should occur
// but the timestamp should still be updated
// -----------------------------------------------------------------------------
access(all)
fun test_collectStability_zeroRate_returnsNil() {
    // setup LP to provide MOET liquidity for borrowing
    let lp = Test.createAccount()
    setupMoetVault(lp, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: lp.address, amount: 10000.0, beFailed: false)

    // LP deposits MOET
    createPosition(admin: PROTOCOL_ACCOUNT, signer: lp, amount: 10000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    // setup borrower with FLOW collateral
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    transferFlowTokens(to: borrower, amount: 1000.0)

    // borrower deposits FLOW and auto-borrows MOET (creates debit balance)
    createPosition(admin: PROTOCOL_ACCOUNT, signer: borrower, amount: 1000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: true)

    // set stability fee rate to 0
    let rateResult = setStabilityFeeRate(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, stabilityFeeRate: 0.0)
    Test.expect(rateResult, Test.beSucceeded())

    let initialBalance = getStabilityFundBalance(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.assertEqual(nil, initialBalance)

    Test.moveTime(by: ONE_YEAR)

    // collect stability - should return nil since rate is 0
    let res = collectStability(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.expect(res, Test.beSucceeded())

    // verify stability fund balance is still nil
    let finalBalance = getStabilityFundBalance(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.assertEqual(nil, finalBalance)
}