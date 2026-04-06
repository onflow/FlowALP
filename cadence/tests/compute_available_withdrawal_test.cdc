import Test
import BlockchainHelpers

import "MOET"
import "FlowALPEvents"
import "FlowALPModels"
import "test_helpers.cdc"

// Tests for the Pool's computeAvailableWithdrawal logic, exercised via
// fundsAvailableAboveTargetHealthAfterDepositing (depositAmount: 0.0 for the base cases).
//
// Token setup used throughout:
//   FLOW: collateralFactor=0.8, borrowFactor=1.0, price=1.0
//   MOET: collateralFactor=1.0, borrowFactor=1.0, price=1.0  (default token)
//
// Health formula:
//   health = effectiveCollateral / effectiveDebt
//   effectiveCollateral(FLOW) = balance * price * CF  = balance * 1.0 * 0.8
//   effectiveDebt(MOET)       = balance * price / BF  = balance * 1.0 / 1.0
//
// TARGET_HEALTH = 1.3

access(all) let user = Test.createAccount()

access(all) let flowCF = 0.8
access(all) let flowBF = 1.0
access(all) let flowPrice = 1.0
access(all) let moetCF = 1.0
access(all) let moetBF = 1.0
access(all) let moetPrice = 1.0

access(all) var snapshot: UInt64 = 0

access(all)
fun beforeEach() {
    if getCurrentBlockHeight() > snapshot {
        Test.reset(to: snapshot)
    }
}

access(all)
fun setup() {
    deployContracts()

    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: flowPrice)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: MOET_TOKEN_IDENTIFIER, price: moetPrice)

    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: flowCF,
        borrowFactor: flowBF,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 10_000.0)

    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    snapshot = getCurrentBlockHeight()
}

// ---------------------------------------------------------------------------
// Test 1: Position already at target health → 0 available for both token types
//
// Setup: 100 FLOW deposited, pushed to draw-down sink (borrowed to target health).
//   effectiveCollateral = 100 * 0.8 = 80
//   maxMOETBorrow = 80 / 1.3 = 61.538...
//   health ≈ target (1.3)
//
// Expected: nothing available to withdraw for either FLOW or MOET.
// ---------------------------------------------------------------------------
access(all)
fun test_atTargetHealth_nothingAvailable() {
    let flowDeposit = 100.0
    let pid = openPosition(flowAmount: flowDeposit, push: true)

    let availableMOET = fundsAvailableAboveTargetHealthAfterDepositing(
        pid: pid,
        withdrawType: MOET_TOKEN_IDENTIFIER,
        targetHealth: INT_TARGET_HEALTH,
        depositType: FLOW_TOKEN_IDENTIFIER,
        depositAmount: 0.0,
        beFailed: false
    )
    Test.assert(equalWithinVariance(0.0, availableMOET, DEFAULT_UFIX_VARIANCE),
        message: "Expected 0 MOET available at target health, got \(availableMOET)")

    let availableFLOW = fundsAvailableAboveTargetHealthAfterDepositing(
        pid: pid,
        withdrawType: FLOW_TOKEN_IDENTIFIER,
        targetHealth: INT_TARGET_HEALTH,
        depositType: MOET_TOKEN_IDENTIFIER,
        depositAmount: 0.0,
        beFailed: false
    )
    Test.assert(equalWithinVariance(0.0, availableFLOW, DEFAULT_UFIX_VARIANCE),
        message: "Expected 0 FLOW available at target health, got \(availableFLOW)")
}

// ---------------------------------------------------------------------------
// Test 2: No credit in withdraw token, zero existing debt
//         → full borrow capacity available (pure debt increase path)
//
// Setup: 100 FLOW, no borrow (push=false).
//   effectiveCollateral = 100 * 0.8 = 80
//   effectiveDebt = 0
//   availableDebtIncrease = 80 / 1.3
//   availableMOET = (80 / 1.3) * 1.0 / 1.0 = 80 / 1.3 ≈ 61.538
//
// This exercises the "no credit in withdraw token" branch at the bottom of
// computeAvailableWithdrawal.
// ---------------------------------------------------------------------------
access(all)
fun test_noCreditInWithdrawToken_zerodebt_fullBorrowCapacity() {
    let flowDeposit = 100.0
    let pid = openPosition(flowAmount: flowDeposit, push: false)

    let effectiveCollateral = flowDeposit * flowCF * flowPrice // 80
    let expectedAvailable = effectiveCollateral / TARGET_HEALTH  // 80 / 1.3

    let actualAvailable = fundsAvailableAboveTargetHealthAfterDepositing(
        pid: pid,
        withdrawType: MOET_TOKEN_IDENTIFIER,
        targetHealth: INT_TARGET_HEALTH,
        depositType: FLOW_TOKEN_IDENTIFIER,
        depositAmount: 0.0,
        beFailed: false
    )
    Test.assert(equalWithinVariance(expectedAvailable, actualAvailable, DEFAULT_UFIX_VARIANCE),
        message: "Expected \(expectedAvailable) MOET available (zero-debt full capacity), got \(actualAvailable)")
}

// ---------------------------------------------------------------------------
// Test 3: Credit in withdraw token, partial collateral withdrawal only
//         → potentialHealth ≤ targetHealth when all credit is removed
//
// Setup:
//   1. 100 FLOW, push=true → borrows 80/1.3 ≈ 61.538 MOET  (health = target)
//   2. Increase FLOW price to 2.0 → effectiveCollateral = 100 * 2.0 * 0.8 = 160
//      effectiveDebt = 61.538 (unchanged, in MOET units)
//      health = 160 / 61.538 ≈ 2.6
//
// Withdraw FLOW (has credit):
//   Removing all 100 FLOW credit → effectiveCollateral goes to 0 (< effectiveDebt) → partial
//   availableEffective = 160 - 1.3 * 61.538 = 160 - 80 = 80
//   availableTokens = 80 / (flowCF * flowPrice_new) = 80 / (0.8 * 2.0) = 50.0
//
// Expected: 50.0 FLOW
// ---------------------------------------------------------------------------
access(all)
fun test_creditInWithdrawToken_partialCollateralOnly() {
    let flowDeposit = 100.0
    let pid = openPosition(flowAmount: flowDeposit, push: true)

    // Confirm the borrow happened and health is at target
    let healthAtCreation = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(equalWithinVariance(UFix64(INT_TARGET_HEALTH), UFix64(healthAtCreation), DEFAULT_UFIX_VARIANCE),
        message: "Expected health ≈ 1.3 after creation with push, got \(healthAtCreation)")

    // Increase FLOW price to 2.0 → more headroom above target
    let newFlowPrice = 2.0
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: newFlowPrice)

    // effectiveCollateral = 100 * 2.0 * 0.8 = 160
    // effectiveDebt = 80/1.3 (borrowed at original price 1.0, in MOET units)
    // NOTE: 80.0/1.3 * 1.3 = 80 (the "required collateral at target health")
    // availableEffective = 160 - 80 = 80
    // availableTokens = 80 / (0.8 * 2.0) = 50.0
    let expectedAvailable = 50.0

    let actualAvailable = fundsAvailableAboveTargetHealthAfterDepositing(
        pid: pid,
        withdrawType: FLOW_TOKEN_IDENTIFIER,
        targetHealth: INT_TARGET_HEALTH,
        depositType: MOET_TOKEN_IDENTIFIER,
        depositAmount: 0.0,
        beFailed: false
    )
    Test.assert(equalWithinVariance(expectedAvailable, actualAvailable, DEFAULT_UFIX_VARIANCE),
        message: "Expected \(expectedAvailable) FLOW available (partial collateral withdrawal), got \(actualAvailable)")
}

// ---------------------------------------------------------------------------
// Test 4: Credit in withdraw token flips into debt — FLO-22 scenario
//         → potentialHealth > targetHealth even after all credit is removed
//
// This verifies the "flip into debt" branch of computeAvailableWithdrawal
// which enables withdrawals beyond the deposited credit balance.
//
// Setup:
//   1. Deposit 100 FLOW (push=false) → 100 FLOW credit, 0 debt
//   2. Deposit 200 MOET to same position (push=false) → 200 MOET credit added
//      effectiveCollateral = 80 (FLOW) + 200 (MOET) = 280
//      effectiveDebt = 0
//
// Withdraw FLOW:
//   Removing all 100 FLOW credit:
//     remaining effectiveCollateral = 280 - 80 = 200
//     potentialHealth = 200 / 0 = infinite > target → flip into debt branch
//   collateralTokenCount = 100
//   availableDebtIncrease = 200 / 1.3 ≈ 153.846
//   additionalFLOW = 153.846 * 1.0 / 1.0 ≈ 153.846
//   total = 100 + 153.846 ≈ 253.846
//
// Expected: 100.0 + 200.0 / 1.3 ≈ 253.846 FLOW
// ---------------------------------------------------------------------------
access(all)
fun test_creditFlipsIntoDebt_availabilityExceedsCreditBalance() {
    let flowDeposit = 100.0
    let moetDeposit = 200.0
    let pid = openPosition(flowAmount: flowDeposit, push: false)

    // Give user MOET to deposit as second collateral
    mintMoet(signer: PROTOCOL_ACCOUNT, to: user.address, amount: moetDeposit, beFailed: false)

    // Deposit MOET as additional collateral (no borrow — push=false)
    depositToPosition(
        signer: user,
        positionID: pid,
        amount: moetDeposit,
        vaultStoragePath: MOET.VaultStoragePath,
        pushToDrawDownSink: false
    )

    // effectiveCollateral = 100 * 0.8 + 200 * 1.0 = 280
    // effectiveDebt = 0
    // After removing all FLOW credit: remaining effectiveCollateral = 200 (MOET only)
    // availableDebtIncrease = 200 / 1.3
    // additionalFLOW = 200 / 1.3 * 1.0 / 1.0
    // total = 100 + 200/1.3
    let expectedAvailable = flowDeposit + moetDeposit / TARGET_HEALTH

    let actualAvailable = fundsAvailableAboveTargetHealthAfterDepositing(
        pid: pid,
        withdrawType: FLOW_TOKEN_IDENTIFIER,
        targetHealth: INT_TARGET_HEALTH,
        depositType: MOET_TOKEN_IDENTIFIER,
        depositAmount: 0.0,
        beFailed: false
    )
    Test.assert(equalWithinVariance(expectedAvailable, actualAvailable, DEFAULT_UFIX_VARIANCE),
        message: "Expected \(expectedAvailable) FLOW available (credit→debt flip), got \(actualAvailable)")
}

access(self)
fun openPosition(flowAmount: UFix64, push: Bool): UInt64 {
    let openRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [flowAmount, FLOW_VAULT_STORAGE_PATH, push],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    let evts = Test.eventsOfType(Type<FlowALPEvents.Opened>())
    let openedEvt = evts[evts.length - 1] as! FlowALPEvents.Opened
    return openedEvt.pid
}