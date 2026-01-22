import Test
import BlockchainHelpers

import "MOET"
import "FlowToken"
import "test_helpers.cdc"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) var snapshot: UInt64 = 0
access(all) let flowVaultStoragePath = /storage/flowTokenVault

access(all)
fun setup() {
    deployContracts()
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)

    // Add FlowToken as a supported collateral type (needed for borrowing scenarios)
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)
    addSupportedTokenZeroRateCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
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
    mintMoet(signer: protocolAccount, to: lp.address, amount: 10000.0, beFailed: false)
    grantPoolCapToConsumer()
    
    // LP deposits MOET (creates credit balance, provides borrowing liquidity)
    createWrappedPosition(signer: lp, amount: 10000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    // setup borrower with FLOW collateral to create debit balance
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    transferFlowTokens(to: borrower, amount: 1000.0)

    // borrower deposits FLOW and auto-borrows MOET (creates debit balance)
    createWrappedPosition(signer: borrower, amount: 1000.0, vaultStoragePath: flowVaultStoragePath, pushToDrawDownSink: true)

    // set 10% annual debit rate (stability is calculated on interest income)
    setInterestCurveFixed(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, yearlyRate: 0.1)

    // set stability fee rate (10% of interest income)
    let rateResult = setStabilityFeeRate(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, stabilityFeeRate: 0.1)
    Test.expect(rateResult, Test.beSucceeded())

    // advance time to accrue stability fees
    Test.moveTime(by: secondsInYear)

    // collect stability fees
    let collectRes = collectStability(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier)
    Test.expect(collectRes, Test.beSucceeded())

    // return the collected amount
    return getStabilityFundBalance(tokenTypeIdentifier: defaultTokenIdentifier)!
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
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        amount: 100.0,
        recipient: protocolAccount.address,
        recipientPath: MOET.ReceiverPublicPath,
    )
    Test.expect(result, Test.beFailed())
    Test.assertError(result, errorMessage: "No stability fund exists for token type \(defaultTokenIdentifier)")
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
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        amount: 0.0,
        recipient: protocolAccount.address,
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
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        amount: excessAmount,
        recipient: protocolAccount.address,
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
    setupMoetVault(protocolAccount, beFailed: false)
    let recipientBalanceBefore = getBalance(address: protocolAccount.address, vaultPublicPath: MOET.VaultPublicPath)

    // withdraw half the amount
    let withdrawAmount = collectedAmount / 2.0
    let result = withdrawStabilityFund(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        amount: withdrawAmount,
        recipient: protocolAccount.address,
        recipientPath: MOET.ReceiverPublicPath,
    )
    Test.expect(result, Test.beSucceeded())

    // verify stability fund has remaining balance
    let fundBalanceAfter = getStabilityFundBalance(tokenTypeIdentifier: defaultTokenIdentifier)
    let expectedRemaining = collectedAmount - withdrawAmount
    Test.assertEqual(expectedRemaining, fundBalanceAfter!)

    // verify recipient received the tokens
    let recipientBalanceAfter = getBalance(address: protocolAccount.address, vaultPublicPath: MOET.VaultPublicPath)
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
    let recipientBalanceBefore = getBalance(address: protocolAccount.address, vaultPublicPath: MOET.VaultPublicPath)

    // withdraw full amount
    let result = withdrawStabilityFund(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        amount: collectedAmount,
        recipient: protocolAccount.address,
        recipientPath: MOET.ReceiverPublicPath,
    )
    Test.expect(result, Test.beSucceeded())

    // verify stability fund is now empty
    let fundBalanceAfter = getStabilityFundBalance(tokenTypeIdentifier: defaultTokenIdentifier)
    Test.assertEqual(0.0, fundBalanceAfter!)

    // verify recipient received the tokens
    let recipientBalanceAfter = getBalance(address: protocolAccount.address, vaultPublicPath: MOET.VaultPublicPath)
    Test.assertEqual(recipientBalanceBefore! + collectedAmount, recipientBalanceAfter!)
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
    setupMoetVault(protocolAccount, beFailed: false)
    let recipientBalanceBefore = getBalance(address: protocolAccount.address, vaultPublicPath: MOET.VaultPublicPath)

    // first withdrawal - 1/3 of balance
    let firstWithdraw = collectedAmount / 3.0
    let result1 = withdrawStabilityFund(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        amount: firstWithdraw,
        recipient: protocolAccount.address,
        recipientPath: MOET.ReceiverPublicPath,
    )
    Test.expect(result1, Test.beSucceeded())

    let fundBalanceAfterFirst = getStabilityFundBalance(tokenTypeIdentifier: defaultTokenIdentifier)
    let expectedAfterFirst = collectedAmount - firstWithdraw
    Test.assertEqual(expectedAfterFirst, fundBalanceAfterFirst!)

    // second withdrawal - another 1/3 of original balance
    let secondWithdraw = collectedAmount / 3.0
    let result2 = withdrawStabilityFund(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        amount: secondWithdraw,
        recipient: protocolAccount.address,
        recipientPath: MOET.ReceiverPublicPath,
    )
    Test.expect(result2, Test.beSucceeded())

    let fundBalanceAfterSecond = getStabilityFundBalance(tokenTypeIdentifier: defaultTokenIdentifier)
    let expectedAfterSecond = expectedAfterFirst - secondWithdraw
    Test.assertEqual(expectedAfterSecond, fundBalanceAfterSecond!)

    // verify total received by recipient
    let recipientBalanceAfter = getBalance(address: protocolAccount.address, vaultPublicPath: MOET.VaultPublicPath)
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
    setupMoetVault(protocolAccount, beFailed: false)

    // withdraw half initially
    let firstWithdraw = initialCollected / 2.0
    let result1 = withdrawStabilityFund(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        amount: firstWithdraw,
        recipient: protocolAccount.address,
        recipientPath: MOET.ReceiverPublicPath,
    )
    Test.expect(result1, Test.beSucceeded())

    let balanceAfterFirstWithdraw = getStabilityFundBalance(tokenTypeIdentifier: defaultTokenIdentifier)!

    // advance more time and collect more stability
    Test.moveTime(by: secondsInYear)
    let collectRes2 = collectStability(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier)
    Test.expect(collectRes2, Test.beSucceeded())

    let balanceAfterSecondCollection = getStabilityFundBalance(tokenTypeIdentifier: defaultTokenIdentifier)!
    Test.assert(balanceAfterSecondCollection > balanceAfterFirstWithdraw, message: "Balance should increase after second collection")

    // withdraw the new total
    let result2 = withdrawStabilityFund(
        signer: protocolAccount,
        tokenTypeIdentifier: defaultTokenIdentifier,
        amount: balanceAfterSecondCollection,
        recipient: protocolAccount.address,
        recipientPath: MOET.ReceiverPublicPath,
    )
    Test.expect(result2, Test.beSucceeded())

    // verify fund is empty
    let finalBalance = getStabilityFundBalance(tokenTypeIdentifier: defaultTokenIdentifier)
    Test.assertEqual(0.0, finalBalance!)
}