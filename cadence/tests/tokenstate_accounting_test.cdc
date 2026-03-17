import Test
import BlockchainHelpers

import "MOET"
import "FlowToken"
import "FlowALPv0"
import "FlowALPModels"
import "FlowALPMath"
import "test_helpers.cdc"

// =============================================================================
// TokenState Total Credit/Debit Accounting Consistency Tests
// =============================================================================
// These tests verify whether TokenState's totalCreditBalance and
// totalDebitBalance remain consistent with the sum of individual position
// balances as interest accrues over time.
//
// The hypothesis: totalCreditBalance/totalDebitBalance are updated with
// instantaneous "true" amounts at deposit/withdrawal time, but are never
// compounded with interest. As interest accrues, the sum of true position
// balances diverges from totalCreditBalance, because each position's true
// balance grows via scaledBalance × interestIndex, while totalCreditBalance
// remains a stale sum of point-in-time additions/subtractions.
// =============================================================================

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()
    snapshot = getCurrentBlockHeight()
}

// =============================================================================
// Test: Single position credit balance diverges from totalCreditBalance
// =============================================================================
// Scenario:
// 1. Create a single position with 100 FLOW credit
// 2. Set FLOW interest rate to 10% APY (FixedCurve)
// 3. Advance time by 1 year
// 4. Position's true balance should be ~110 FLOW (100 * 1.10)
// 5. Withdraw 100 FLOW (the original deposit amount)
// 6. Position's remaining true balance should be ~10 FLOW (accrued interest)
// 7. But totalCreditBalance = 100 (initial) - 100 (withdrawn) = 0
// 8. This proves the inconsistency: position has ~10 FLOW but total says 0
// =============================================================================
access(all)
fun test_totalCreditBalance_diverges_after_interest_accrual() {
    // -------------------------------------------------------------------------
    // STEP 1: Initialize Protocol Environment
    // -------------------------------------------------------------------------
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)

    // Add FLOW with a zero-rate curve initially (we'll set the rate after deposit)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // -------------------------------------------------------------------------
    // STEP 2: Create a single position with 100 FLOW
    // -------------------------------------------------------------------------
    let lender = Test.createAccount()
    setupMoetVault(lender, beFailed: false)
    mintFlow(to: lender, amount: 100.0)

    // Create position with 100 FLOW (no auto-borrow)
    createPosition(
        admin: PROTOCOL_ACCOUNT,
        signer: lender,
        amount: 100.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )
    let pid: UInt64 = getLastPositionId()
    log("Created position ".concat(pid.toString()).concat(" with 100 FLOW"))

    // -------------------------------------------------------------------------
    // STEP 3: Verify initial state - totalCreditBalance should equal position balance
    // -------------------------------------------------------------------------
    let totalCreditBefore = getTotalCreditBalance(vaultIdentifier: FLOW_TOKEN_IDENTIFIER)
    let detailsBefore = getPositionDetails(pid: pid, beFailed: false)
    let posBalanceBefore = getCreditBalanceForType(details: detailsBefore, vaultType: Type<@FlowToken.Vault>())

    log("Initial totalCreditBalance: ".concat(totalCreditBefore.toString()))
    log("Initial position balance: ".concat(posBalanceBefore.toString()))

    // At time 0, both should be ~100 FLOW (consistent)
    Test.assert(
        ufix128EqualWithinVariance(100.0, totalCreditBefore),
        message: "Initial totalCreditBalance should be ~100, got ".concat(totalCreditBefore.toString())
    )
    Test.assert(
        ufixEqualWithinVariance(100.0, posBalanceBefore),
        message: "Initial position balance should be ~100, got ".concat(posBalanceBefore.toString())
    )

    // -------------------------------------------------------------------------
    // STEP 4: Set FLOW interest rate to 10% APY (FixedCurve)
    // -------------------------------------------------------------------------
    // With FixedCurve, the debit rate is 10%. The credit rate is:
    // creditRate = debitRate * (1 - protocolFeeRate)
    // protocolFeeRate = insuranceRate + stabilityFeeRate = 0.0 + 0.05 = 0.05
    // creditRate = 0.10 * (1 - 0.05) = 0.095 = 9.5% APY
    setInterestCurveFixed(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        yearlyRate: 0.10
    )
    log("Set FLOW interest rate to 10% APY")

    // -------------------------------------------------------------------------
    // STEP 5: Advance time by 1 year
    // -------------------------------------------------------------------------
    let timestampBefore = getBlockTimestamp()
    Test.moveTime(by: ONE_YEAR)
    Test.commitBlock()
    let timestampAfter = getBlockTimestamp()
    let timeDelta = timestampAfter - timestampBefore
    log("Advanced time by ".concat(timeDelta.toString()).concat(" seconds (~1 year)"))

    // -------------------------------------------------------------------------
    // STEP 6: Verify position balance has grown due to interest
    // -------------------------------------------------------------------------
    let detailsAfterYear = getPositionDetails(pid: pid, beFailed: false)
    let posBalanceAfterYear = getCreditBalanceForType(details: detailsAfterYear, vaultType: Type<@FlowToken.Vault>())
    log("Position balance after 1 year: ".concat(posBalanceAfterYear.toString()))

    // The position balance should be approximately 100 * (1 + 0.095) ≈ 109.5
    // (9.5% credit rate due to stability fee deduction)
    Test.assert(
        posBalanceAfterYear > 109.0 && posBalanceAfterYear < 110.5,
        message: "Position balance after 1 year should be ~109.5 (100 + 9.5% interest), got ".concat(posBalanceAfterYear.toString())
    )

    // Check what totalCreditBalance says - it should ALSO be ~109.5 if accounting is correct
    let totalCreditAfterYear = getTotalCreditBalance(vaultIdentifier: FLOW_TOKEN_IDENTIFIER)
    log("totalCreditBalance after 1 year: ".concat(totalCreditAfterYear.toString()))

    // BUG EVIDENCE: totalCreditBalance is still 100, not ~109.5
    // This is because it was never compounded with interest
    Test.assert(
        ufix128EqualWithinVariance(100.0, totalCreditAfterYear),
        message: "totalCreditBalance after 1 year is STILL 100 (not compounded). Got: ".concat(totalCreditAfterYear.toString())
    )

    // -------------------------------------------------------------------------
    // STEP 7: Withdraw the original 100 FLOW
    // -------------------------------------------------------------------------
    withdrawFromPosition(
        signer: lender,
        positionId: pid,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        amount: 100.0,
        pullFromTopUpSource: false
    )
    log("Withdrew 100 FLOW from position")

    // -------------------------------------------------------------------------
    // STEP 8: Prove the inconsistency
    // -------------------------------------------------------------------------
    let detailsAfterWithdraw = getPositionDetails(pid: pid, beFailed: false)
    let posBalanceAfterWithdraw = getCreditBalanceForType(details: detailsAfterWithdraw, vaultType: Type<@FlowToken.Vault>())
    let totalCreditAfterWithdraw = getTotalCreditBalance(vaultIdentifier: FLOW_TOKEN_IDENTIFIER)

    log("Position balance after withdraw: ".concat(posBalanceAfterWithdraw.toString()))
    log("totalCreditBalance after withdraw: ".concat(totalCreditAfterWithdraw.toString()))

    // The position still has ~9.5 FLOW remaining (accrued interest)
    Test.assert(
        posBalanceAfterWithdraw > 9.0 && posBalanceAfterWithdraw < 11.0,
        message: "Position should have ~9.5 FLOW remaining (accrued interest), got ".concat(posBalanceAfterWithdraw.toString())
    )

    // BUG: totalCreditBalance = 100 - 100 = 0, but should be ~9.5
    // This is the core inconsistency: the position has real FLOW credit,
    // but totalCreditBalance says 0
    Test.assert(
        ufix128EqualWithinVariance(0.0, totalCreditAfterWithdraw),
        message: "totalCreditBalance should be 0 (100 initial - 100 withdrawn, never compounded). Got: ".concat(totalCreditAfterWithdraw.toString())
    )

    // This is the proof: position has ~9.5 FLOW but totalCreditBalance = 0
    // The gap is exactly the amount of untracked accrued interest
    Test.assert(
        posBalanceAfterWithdraw > 9.0,
        message: "Position has real FLOW credit that totalCreditBalance doesn't account for"
    )

    log("=== BUG CONFIRMED ===")
    log("Position true credit balance: ".concat(posBalanceAfterWithdraw.toString()))
    log("totalCreditBalance on TokenState: ".concat(totalCreditAfterWithdraw.toString()))
    log("The gap of ~".concat(posBalanceAfterWithdraw.toString()).concat(" FLOW is untracked accrued interest"))
}

// =============================================================================
// Test: Multiple positions amplify the divergence
// =============================================================================
// This test shows the problem compounds with multiple positions and time:
// - Position A deposits 100 FLOW at time 0
// - Time passes (interest accrues but totalCreditBalance is not updated)
// - Position B deposits 100 FLOW at time 1
// - The totalCreditBalance (200) understates reality (~210)
// =============================================================================
access(all)
fun test_totalCreditBalance_understates_with_multiple_positions() {
    Test.reset(to: snapshot)

    // -------------------------------------------------------------------------
    // Setup: Pool with FLOW at 10% rate
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Position A: Deposits 100 FLOW at time 0
    // -------------------------------------------------------------------------
    let lenderA = Test.createAccount()
    setupMoetVault(lenderA, beFailed: false)
    mintFlow(to: lenderA, amount: 100.0)

    createPosition(
        admin: PROTOCOL_ACCOUNT,
        signer: lenderA,
        amount: 100.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )
    let pidA: UInt64 = getLastPositionId()

    // Set interest rate after first deposit
    setInterestCurveFixed(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        yearlyRate: 0.10
    )

    // totalCreditBalance = 100 (correct at this point)
    let totalAfterA = getTotalCreditBalance(vaultIdentifier: FLOW_TOKEN_IDENTIFIER)
    log("After Position A deposit: totalCreditBalance = ".concat(totalAfterA.toString()))

    // -------------------------------------------------------------------------
    // Advance 1 year: Position A's true balance grows to ~109.5
    // -------------------------------------------------------------------------
    Test.moveTime(by: ONE_YEAR)
    Test.commitBlock()

    let detailsA = getPositionDetails(pid: pidA, beFailed: false)
    let balanceA = getCreditBalanceForType(details: detailsA, vaultType: Type<@FlowToken.Vault>())
    log("Position A balance after 1 year: ".concat(balanceA.toString()))

    // -------------------------------------------------------------------------
    // Position B: Deposits 100 FLOW at time 1
    // -------------------------------------------------------------------------
    let lenderB = Test.createAccount()
    setupMoetVault(lenderB, beFailed: false)
    mintFlow(to: lenderB, amount: 100.0)

    createPosition(
        admin: PROTOCOL_ACCOUNT,
        signer: lenderB,
        amount: 100.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )
    let pidB: UInt64 = getLastPositionId()

    // -------------------------------------------------------------------------
    // Compare: totalCreditBalance vs sum of true position balances
    // -------------------------------------------------------------------------
    let totalAfterB = getTotalCreditBalance(vaultIdentifier: FLOW_TOKEN_IDENTIFIER)

    let detailsAFinal = getPositionDetails(pid: pidA, beFailed: false)
    let balanceAFinal = getCreditBalanceForType(details: detailsAFinal, vaultType: Type<@FlowToken.Vault>())

    let detailsBFinal = getPositionDetails(pid: pidB, beFailed: false)
    let balanceBFinal = getCreditBalanceForType(details: detailsBFinal, vaultType: Type<@FlowToken.Vault>())

    let sumOfTrueBalances = balanceAFinal + balanceBFinal

    log("totalCreditBalance: ".concat(totalAfterB.toString()))
    log("Position A true balance: ".concat(balanceAFinal.toString()))
    log("Position B true balance: ".concat(balanceBFinal.toString()))
    log("Sum of true balances: ".concat(sumOfTrueBalances.toString()))

    // totalCreditBalance = 100 (from A at t=0) + 100 (from B at t=1) = 200
    // But sum of true balances = ~109.5 (A with interest) + 100 (B fresh) = ~209.5
    Test.assert(
        ufix128EqualWithinVariance(200.0, totalAfterB),
        message: "totalCreditBalance should be 200 (sum of raw deposits). Got: ".concat(totalAfterB.toString())
    )

    Test.assert(
        sumOfTrueBalances > 209.0 && sumOfTrueBalances < 211.0,
        message: "Sum of true balances should be ~209.5. Got: ".concat(sumOfTrueBalances.toString())
    )

    // The gap: totalCreditBalance understates reality by ~9.5 FLOW (the untracked interest)
    let gap = sumOfTrueBalances - UFix64(totalAfterB)
    Test.assert(
        gap > 9.0,
        message: "Gap between true balances and totalCreditBalance should be ~9.5 FLOW. Got: ".concat(gap.toString())
    )

    log("=== BUG CONFIRMED (MULTI-POSITION) ===")
    log("totalCreditBalance: ".concat(totalAfterB.toString()))
    log("Sum of true balances: ".concat(sumOfTrueBalances.toString()))
    log("Gap (untracked interest): ".concat(gap.toString()))
}
