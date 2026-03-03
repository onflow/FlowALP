import Test
import BlockchainHelpers

import "MOET"
import "FlowToken"
import "FlowALPv0"
import "FlowALPEvents"
import "test_helpers.cdc"

access(all) var snapshot: UInt64 = 0

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

    // take snapshot first, then advance time so reset() target is always lower than current height
    snapshot = getCurrentBlockHeight()
    // move time by 1 second so Test.reset() works properly before each test
    Test.moveTime(by: 1.0)
}

access(all)
fun beforeEach() {
    Test.reset(to: snapshot)
}

// Helper function to setup stability fund with collected fees
// Returns the amount collected in the stability fund
access(all)
fun setupStabilityFundWithBalance(): UFix64 {
    // setup LP to provide MOET liquidity for borrowing
    let lp = Test.createAccount()
    setupMoetVault(lp, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: lp.address, amount: 10000.0, beFailed: false)

    // LP deposits MOET (creates credit balance, provides borrowing liquidity)
    createPosition(admin: PROTOCOL_ACCOUNT, signer: lp, amount: 10000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    // setup borrower with FLOW collateral to create debit balance
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    transferFlowTokens(to: borrower, amount: 1000.0)

    // borrower deposits FLOW and auto-borrows MOET (creates debit balance)
    createPosition(admin: PROTOCOL_ACCOUNT, signer: borrower, amount: 1000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: true)

    // set 10% annual debit rate (stability is calculated on interest income)
    setInterestCurveFixed(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, yearlyRate: 0.1)

    // set stability fee rate (10% of interest income)
    let rateResult = setStabilityFeeRate(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, stabilityFeeRate: 0.1)
    Test.expect(rateResult, Test.beSucceeded())

    // advance time to accrue stability fees
    Test.moveTime(by: ONE_YEAR)

    // collect stability fees
    let collectRes = collectStability(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.expect(collectRes, Test.beSucceeded())

    // return the collected amount
    return getStabilityFundBalance(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)!
}

// -----------------------------------------------------------------------------
// Test: withdrawStabilityFund fails when no stability fund exists for token
// Verifies that attempting to withdraw from non-existent fund fails
// -----------------------------------------------------------------------------
access(all)
fun test_withdrawStabilityFund_fails_noFundExists() {
    // FlowToken has no stability fund (no stability has been collected for it)
    // Try to withdraw from non-existent fund
    let result = withdrawStabilityFund(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        amount: 100.0,
        recipient: PROTOCOL_ACCOUNT.address,
        recipientPath: MOET.ReceiverPublicPath,
    )
    Test.expect(result, Test.beFailed())
    Test.assertError(result, errorMessage: "No stability fund exists for token type \(MOET_TOKEN_IDENTIFIER)")
}

// -----------------------------------------------------------------------------
// Test: withdrawStabilityFund fails when amount is zero
// Verifies that zero withdrawal amount is rejected
// -----------------------------------------------------------------------------
access(all)
fun test_withdrawStabilityFund_fails_zeroAmount() {
    let collectedAmount = setupStabilityFundWithBalance()
    Test.assert(collectedAmount > 0.0, message: "Stability fund should have balance after collection")

    // try to withdraw zero amount
    let result = withdrawStabilityFund(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        amount: 0.0,
        recipient: PROTOCOL_ACCOUNT.address,
        recipientPath: MOET.ReceiverPublicPath,
    )
    Test.expect(result, Test.beFailed())
    Test.assertError(result, errorMessage: "Withdrawal amount must be positive")
}

// -----------------------------------------------------------------------------
// Test: withdrawStabilityFund fails when amount exceeds balance
// Verifies that withdrawing more than available balance fails
// -----------------------------------------------------------------------------
access(all)
fun test_withdrawStabilityFund_fails_insufficientBalance() {
    let collectedAmount = setupStabilityFundWithBalance()
    Test.assert(collectedAmount > 0.0, message: "Stability fund should have balance after collection")

    // try to withdraw more than available
    let excessAmount = collectedAmount + 1000.0
    let result = withdrawStabilityFund(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        amount: excessAmount,
        recipient: PROTOCOL_ACCOUNT.address,
        recipientPath: MOET.ReceiverPublicPath,
    )
    Test.expect(result, Test.beFailed())
    Test.assertError(result, errorMessage: "Insufficient stability fund balance")
}

// -----------------------------------------------------------------------------
// Test: withdrawStabilityFund successfully withdraws partial amount
// Verifies that governance can withdraw a portion of the stability fund
// -----------------------------------------------------------------------------
access(all)
fun test_withdrawStabilityFund_success_partialAmount() {
    let collectedAmount = setupStabilityFundWithBalance()
    Test.assert(collectedAmount > 0.0, message: "Stability fund should have balance after collection")

    // setup recipient vault
    setupMoetVault(PROTOCOL_ACCOUNT, beFailed: false)
    let recipientBalanceBefore = getBalance(address: PROTOCOL_ACCOUNT.address, vaultPublicPath: MOET.VaultPublicPath)

    // withdraw half the amount
    let withdrawAmount = collectedAmount / 2.0
    let result = withdrawStabilityFund(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        amount: withdrawAmount,
        recipient: PROTOCOL_ACCOUNT.address,
        recipientPath: MOET.ReceiverPublicPath,
    )
    Test.expect(result, Test.beSucceeded())

    // verify stability fund has remaining balance
    let fundBalanceAfter = getStabilityFundBalance(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    let expectedRemaining = collectedAmount - withdrawAmount
    Test.assertEqual(expectedRemaining, fundBalanceAfter!)

    // verify recipient received the tokens
    let recipientBalanceAfter = getBalance(address: PROTOCOL_ACCOUNT.address, vaultPublicPath: MOET.VaultPublicPath)
    Test.assertEqual(recipientBalanceBefore! + withdrawAmount, recipientBalanceAfter!)
}

// -----------------------------------------------------------------------------
// Test: withdrawStabilityFund successfully withdraws full amount
// Verifies that governance can withdraw the entire stability fund balance
// -----------------------------------------------------------------------------
access(all)
fun test_withdrawStabilityFund_success_fullAmount() {
    let collectedAmount = setupStabilityFundWithBalance()
    Test.assert(collectedAmount > 0.0, message: "Stability fund should have balance after collection")

    // setup recipient vault
    let recipientBalanceBefore = getBalance(address: PROTOCOL_ACCOUNT.address, vaultPublicPath: MOET.VaultPublicPath)

    // withdraw full amount
    let result = withdrawStabilityFund(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        amount: collectedAmount,
        recipient: PROTOCOL_ACCOUNT.address,
        recipientPath: MOET.ReceiverPublicPath,
    )
    Test.expect(result, Test.beSucceeded())

    // verify stability fund is now empty
    let fundBalanceAfter = getStabilityFundBalance(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.assertEqual(0.0, fundBalanceAfter!)

    // verify recipient received the tokens
    let recipientBalanceAfter = getBalance(address: PROTOCOL_ACCOUNT.address, vaultPublicPath: MOET.VaultPublicPath)
    Test.assertEqual(recipientBalanceBefore! + collectedAmount, recipientBalanceAfter!)

    // verify StabilityFundWithdrawn event was emitted
    let events = Test.eventsOfType(Type<FlowALPEvents.StabilityFundWithdrawn>())
    Test.assert(events.length > 0, message: "StabilityFundWithdrawn event should be emitted")
    let stabilityFundWithdrawnEvent = events[events.length - 1] as! FlowALPEvents.StabilityFundWithdrawn
    Test.assertEqual(MOET_TOKEN_IDENTIFIER, stabilityFundWithdrawnEvent.tokenType)
    Test.assertEqual(collectedAmount, stabilityFundWithdrawnEvent.amount)
}

// -----------------------------------------------------------------------------
// Test: withdrawStabilityFund multiple withdrawals
// Verifies that multiple sequential withdrawals work correctly
// -----------------------------------------------------------------------------
access(all)
fun test_withdrawStabilityFund_multipleWithdrawals() {
    let collectedAmount = setupStabilityFundWithBalance()
    Test.assert(collectedAmount > 0.0, message: "Stability fund should have balance after collection")

    // setup recipient vault
    setupMoetVault(PROTOCOL_ACCOUNT, beFailed: false)
    let recipientBalanceBefore = getBalance(address: PROTOCOL_ACCOUNT.address, vaultPublicPath: MOET.VaultPublicPath)

    // first withdrawal - 1/3 of balance
    let firstWithdraw = collectedAmount / 3.0
    let result1 = withdrawStabilityFund(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        amount: firstWithdraw,
        recipient: PROTOCOL_ACCOUNT.address,
        recipientPath: MOET.ReceiverPublicPath,
    )
    Test.expect(result1, Test.beSucceeded())

    let fundBalanceAfterFirst = getStabilityFundBalance(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    let expectedAfterFirst = collectedAmount - firstWithdraw
    Test.assertEqual(expectedAfterFirst, fundBalanceAfterFirst!)

    // second withdrawal - another 1/3 of original balance
    let secondWithdraw = collectedAmount / 3.0
    let result2 = withdrawStabilityFund(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        amount: secondWithdraw,
        recipient: PROTOCOL_ACCOUNT.address,
        recipientPath: MOET.ReceiverPublicPath,
    )
    Test.expect(result2, Test.beSucceeded())

    let fundBalanceAfterSecond = getStabilityFundBalance(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    let expectedAfterSecond = expectedAfterFirst - secondWithdraw
    Test.assertEqual(expectedAfterSecond, fundBalanceAfterSecond!)

    // verify total received by recipient
    let recipientBalanceAfter = getBalance(address: PROTOCOL_ACCOUNT.address, vaultPublicPath: MOET.VaultPublicPath)
    Test.assertEqual(recipientBalanceBefore! + firstWithdraw + secondWithdraw, recipientBalanceAfter!)
}

// -----------------------------------------------------------------------------
// Test: withdrawStabilityFund after additional collection
// Verifies that withdrawal works correctly after collecting more stability fees
// -----------------------------------------------------------------------------
access(all)
fun test_withdrawStabilityFund_afterAdditionalCollection() {
    let initialCollected = setupStabilityFundWithBalance()
    Test.assert(initialCollected > 0.0, message: "Stability fund should have balance after collection")

    // setup recipient vault
    setupMoetVault(PROTOCOL_ACCOUNT, beFailed: false)

    // withdraw half initially
    let firstWithdraw = initialCollected / 2.0
    let result1 = withdrawStabilityFund(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        amount: firstWithdraw,
        recipient: PROTOCOL_ACCOUNT.address,
        recipientPath: MOET.ReceiverPublicPath,
    )
    Test.expect(result1, Test.beSucceeded())

    let balanceAfterFirstWithdraw = getStabilityFundBalance(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)!

    // advance more time and collect more stability
    Test.moveTime(by: ONE_YEAR)
    let collectRes2 = collectStability(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.expect(collectRes2, Test.beSucceeded())

    let balanceAfterSecondCollection = getStabilityFundBalance(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)!
    Test.assert(balanceAfterSecondCollection > balanceAfterFirstWithdraw, message: "Balance should increase after second collection")

    // withdraw the new total
    let result2 = withdrawStabilityFund(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        amount: balanceAfterSecondCollection,
        recipient: PROTOCOL_ACCOUNT.address,
        recipientPath: MOET.ReceiverPublicPath,
    )
    Test.expect(result2, Test.beSucceeded())

    // verify fund is empty
    let finalBalance = getStabilityFundBalance(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER)
    Test.assertEqual(0.0, finalBalance!)
}
