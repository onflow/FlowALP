import Test
import BlockchainHelpers

import "MOET"
import "FlowToken"
import "FlowALPEvents"
import "test_helpers.cdc"

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()
    // take snapshot first, then advance time so reset() target is always lower than current height
    snapshot = getCurrentBlockHeight()
    // move time by 1 second so Test.reset() works properly before each test
    Test.moveTime(by: 1.0)
}

access(all)
fun beforeEach() {
    Test.reset(to: snapshot)
    
    // Recreate pool and supported tokens fresh for each test
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 0.9,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )
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
// Test: collectStability does not collect when reserves are insufficient
// If the calculated stability fee exceeds the reserve balance,
// no stability fee should be collected and reserves remain unchanged.
// -----------------------------------------------------------------------------
access(all)
fun test_collectStability_insufficientReserves() {
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
    // With CF(0.8) and targetHealth(1.3): 10000 FLOW * 0.8 / 1.3 ≈ 6153 MOET borrowable
    // but pool only has 1000 MOET, so borrower gets ~1000 MOET (limited by liquidity)
    // this leaves reserves very close to 0
    createPosition(admin: PROTOCOL_ACCOUNT, signer: borrower, amount: 10000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: true)

    let initialStabilityBalance = getStabilityFundBalance(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.assertEqual(nil, initialStabilityBalance)

    let reserveBalanceBefore = getReserveBalance(vaultIdentifier: MOET_TOKEN_IDENTIFIER)
    let lastCollectionTimeBefore = getLastStabilityCollectionTime(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)

    Test.moveTime(by: ONE_YEAR + DAY * 30.0) // 1 year + 1 month

    // should not collect because reserves are insufficient
    let res = collectStability(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.expect(res, Test.beSucceeded())

    let finalStabilityBalance = getStabilityFundBalance(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    let reserveBalanceAfter = getReserveBalance(vaultIdentifier: MOET_TOKEN_IDENTIFIER)
    let lastCollectionTimeAfter = getLastStabilityCollectionTime(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)

    Test.assertEqual(nil, finalStabilityBalance)
    Test.assertEqual(reserveBalanceBefore, reserveBalanceAfter)

    // time should not change
    Test.assertEqual(lastCollectionTimeBefore, lastCollectionTimeAfter)
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
    // set 10% annual debit rates
    // Stability is calculated on interest income, not debit balance directly
    setInterestCurveFixed(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, yearlyRate: 0.1)
    setInterestCurveFixed(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER, yearlyRate: 0.1)

    let moetRateResult = setStabilityFeeRate(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, stabilityFeeRate: 0.1)
    Test.expect(moetRateResult, Test.beSucceeded())

    let flowRateResult = setStabilityFeeRate(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER, stabilityFeeRate: 0.05)
    Test.expect(flowRateResult, Test.beSucceeded())

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
    borrowFromPosition(signer: flowBorrower, positionId: 3, tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, amount: 500.0, beFailed: false)

    // verify initial state — both funds must be nil since rates were set before any borrowing
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

// -----------------------------------------------------------------------------
/// Verifies that stability fee collection remains correct when the stability
/// fee rate changes between collection periods. Rate changes must trigger fee collections,
/// so that all fees due under the previous rate are collected before the new rate comes into effect.
// -----------------------------------------------------------------------------
access(all)
fun test_collectStability_midPeriodRateChange() {
    // set interest curve
    setInterestCurveFixed(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER, yearlyRate: 0.1)

    // provide FLOW liquidity so the borrower can actually borrow
    let lp = Test.createAccount()
    let resMint = mintFlow(to: lp, amount: 10000.0)
    Test.expect(resMint, Test.beSucceeded())
    createPosition(admin: PROTOCOL_ACCOUNT, signer: lp, amount: 10000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    // borrower deposits 1000 MOET as collateral
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: borrower.address, amount: 1000.0, beFailed: false)
    createPosition(admin: PROTOCOL_ACCOUNT, signer: borrower, amount: 1000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    let openEvents = Test.eventsOfType(Type<FlowALPEvents.Opened>())
    let pid = (openEvents[openEvents.length - 1] as! FlowALPEvents.Opened).pid

    // collateralValue = 1000 MOET * price(MOET=1.0) * CF(1) = 1000$
    // targetDebtValue = collateralValue / targetHealth(1.3) = 1000/1.3 = 769.2307692$
    // Max FLOW borrow = targetDebtValue * BF(0.9) / price(FLOW=1.0) ≈ 692.3076923 FLOW

    // borrow 500 FLOW
    borrowFromPosition(
        signer: borrower,
        positionId: pid,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        amount: 500.0,
        beFailed: false
    )

    let reservesBefore_phase1 = getReserveBalance(vaultIdentifier: FLOW_TOKEN_IDENTIFIER)

    // Advance ONE_YEAR
    Test.moveTime(by: ONE_YEAR)

    // Phase 1 expected stability calculation:
    //   yearly rate        = 0.1   (yearly debit rate, FixedCurve)
    //   stabilityFeeRate1  = 0.05  (default)
    //
    //   stabilityIncome_1 = totalDebitBalance * (pow(perSecondDebitRate, timeElapsed) - 1.0)
    //   perSecondRate = 1 + (yearlyRate / 31_557_600)
    //   stabilityAmount = stabilityIncome * stabilityFeeRate
    //
    //   perSecondRate     = 1 + (0.1 / 31557600) = 1.00000000317
    //   stabilityIncome_1 = 500 * (1.00000000317^31557600 - 1) = 52.58545895 FLOW
    //   stabilityAmount_1 = stabilityIncome_1 * stabilityFeeRate1 = 52.58545895 * 0.05 = 2.62927294
    let expectedStabilityAmountAfterPhase1 = 2.62927294

    // change the stability fee rate to 20% for phase 2
    var rateResult = setStabilityFeeRate(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER, stabilityFeeRate: 0.2)
    Test.expect(rateResult, Test.beSucceeded())

    let stabilityAfterPhase1 = getStabilityFundBalance(tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER)!
    let reservesAfterPhase1 = getReserveBalance(vaultIdentifier: FLOW_TOKEN_IDENTIFIER)
    let collected_phase1 = reservesBefore_phase1 - reservesAfterPhase1

    // NOTE:
    // We intentionally do not use `equalWithinVariance` with `defaultUFixVariance` here.
    // The default variance is designed for deterministic math, but stability collection
    // depends on block timestamps, which can differ slightly between test runs.
    // A larger, time-aware tolerance is required.
    let tolerance = 0.00001
    var diff = expectedStabilityAmountAfterPhase1 > stabilityAfterPhase1
        ? expectedStabilityAmountAfterPhase1 - stabilityAfterPhase1
        : stabilityAfterPhase1 - expectedStabilityAmountAfterPhase1
    Test.assert(diff < tolerance, message: "Stability collected should be around \(expectedStabilityAmountAfterPhase1) but current \(stabilityAfterPhase1)")

    // stability fund balance must equal what was withdrawn from reserves
    // (no swap needed — stability is collected in the same token as the reserve)
    Test.assertEqual(collected_phase1, stabilityAfterPhase1)

    let reservesBefore_phase2 = getReserveBalance(vaultIdentifier: FLOW_TOKEN_IDENTIFIER)

    // Advance another ONE_YEAR
    Test.moveTime(by: ONE_YEAR)

    // Phase 2 expected stability calculation:
    //   yearly rate        = 0.1   (yearly debit rate, FixedCurve)
    //   stabilityFeeRate2  = 0.2   (fraction of debit income)
    //
    //   totalDebitBalance = 500 FLOW  (scaled balance — does not compound, index does)
    //   stabilityIncome_2 = 500 * (1.00000000317^31557600 - 1) = 52.58545895 FLOW
    //   stabilityAmount_2 = stabilityIncome_2 * stabilityFeeRate2 = 52.58545895 * 0.2 = 10.51709179
    let expectedStabilityAmountAfterPhase2 = 10.51709179

    // change the stability rate to 25%
    rateResult = setStabilityFeeRate(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER, stabilityFeeRate: 0.25)
    Test.expect(rateResult, Test.beSucceeded())

    let stabilityAfterPhase2 = getStabilityFundBalance(tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER)!
    let reservesAfterPhase2 = getReserveBalance(vaultIdentifier: FLOW_TOKEN_IDENTIFIER)

    let expectedStabilityTotal = expectedStabilityAmountAfterPhase1 + expectedStabilityAmountAfterPhase2 // 2.62927294 + 10.51709179
    diff = expectedStabilityTotal > stabilityAfterPhase2
        ? expectedStabilityTotal - stabilityAfterPhase2
        : stabilityAfterPhase2 - expectedStabilityTotal
    Test.assert(diff < tolerance, message: "Stability collected should be around \(expectedStabilityTotal) but current \(stabilityAfterPhase2)")

    // acumulative stability fund must equal sum of both collections
    let collected_phase2 = reservesBefore_phase2 - reservesAfterPhase2
    Test.assertEqual(stabilityAfterPhase2, stabilityAfterPhase1 + collected_phase2)
    Test.assert(collected_phase2 > collected_phase1, message: "Phase 2 collection should exceed phase 1 due to higher rate")
}