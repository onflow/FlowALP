import Test
import BlockchainHelpers

import "MOET"
import "test_helpers.cdc"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)

access(all)
fun setup() {
    deployContracts()
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)
}

// -----------------------------------------------------------------------------
// Test: collectInsurance full success flow with formula verification
// Full flow: deposit to create credit → advance time → collect insurance
// → verify MOET returned, reserves reduced, timestamp updated, and formula
// Formula: insuranceAmount = totalCreditBalance * insuranceRate * (timeElapsed / secondsPerYear)
//
// This test runs in isolation (separate file) to ensure totalCreditBalance
// equals exactly the depositAmount without interference from other tests.
// -----------------------------------------------------------------------------
access(all)
fun test_collectInsurance_success_fullAmount() {
    // setup user and create a position with deposit
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintMoet(signer: protocolAccount, to: user.address, amount: 1000.0, beFailed: false)

    // create position with 500.0 deposit - totalCreditBalance = 500.0 (isolated test)
    grantPoolCapToConsumer()
    createWrappedPosition(signer: user, amount: 500.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    // setup protocol account with MOET vault for the swapper
    setupMoetVault(protocolAccount, beFailed: false)
    mintMoet(signer: protocolAccount, to: protocolAccount.address, amount: 10000.0, beFailed: false)

    // configure insurance swapper (1:1 ratio)
    let swapperResult = setInsuranceSwapper(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, priceRatio: 1.0)
    Test.expect(swapperResult, Test.beSucceeded())

    // set insurance rate (10% annual)
    let rateResult = setInsuranceRate(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, insuranceRate: 0.1)
    Test.expect(rateResult, Test.beSucceeded())

    // collect insurance to reset last insurance collection timestamp,
    // this accounts for timing variation between pool creation and this point
    // (each transaction/script execution advances the block timestamp slightly)
    collectInsurance(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, beFailed: false)

    // record balances after resetting the timestamp
    let initialInsuranceBalance = getInsuranceFundBalance()
    let reserveBalanceBefore = getReserveBalance(vaultIdentifier: defaultTokenIdentifier)
    Test.assert(reserveBalanceBefore > 0.0, message: "Reserves should exist after deposit")

    // record timestamp before advancing time
    let timestampBefore = getBlockTimestamp()

    Test.moveTime(by: secondsInYear)

    collectInsurance(signer: protocolAccount, tokenTypeIdentifier: defaultTokenIdentifier, beFailed: false)

    // verify insurance was collected, reserves decreased
    let finalInsuranceBalance = getInsuranceFundBalance()
    let reserveBalanceAfter = getReserveBalance(vaultIdentifier: defaultTokenIdentifier)
    Test.assert(reserveBalanceAfter < reserveBalanceBefore, message: "Reserves should have decreased after collection")

    let collectedAmount = finalInsuranceBalance - initialInsuranceBalance
    let amountWithdrawnFromReserves = reserveBalanceBefore - reserveBalanceAfter
    Test.assert(collectedAmount > 0.0, message: "Insurance fund should have received MOET")

    // verify the amount withdrawn from reserves equals the collected amount (1:1 swap ratio)
    Test.assert(ufixEqualWithinVariance(amountWithdrawnFromReserves, collectedAmount), message: "Amount withdrawn from reserves should equal collected amount")

    // verify last insurance collection time was updated to current block timestamp
    let currentTimestamp = getBlockTimestamp()
    let lastInsuranceCollectionTime = getLastInsuranceCollectionTime(tokenTypeIdentifier: defaultTokenIdentifier)
    Test.assert(ufixEqualWithinVariance(currentTimestamp, lastInsuranceCollectionTime!), message: "lastInsuranceCollectionTime should match current timestamp")

    // verify formula: insuranceAmount = totalCreditBalance * insuranceRate * (timeElapsed / secondsPerYear)
    // Expected: 500.0 * 0.1 * (secondsInYear / secondsInYear) = 50.0 MOET
    // Multiple script calls (getInsuranceFundBalance, getReserveBalance, getBlockTimestamp) - each advances the block timestamp slightly
    // and that's why the time passed can be more than secondsInYear by few sec (usually 1 sec)
    Test.assert(
        ufixEqualWithinVariance(50.0, collectedAmount)                  // time passed = secondsInYear
        || ufixEqualWithinVariance(50.00000158, collectedAmount)        // time passed = secondsInYear + 1 sec
        || ufixEqualWithinVariance(50.00000316, collectedAmount)        // time passed = secondsInYear + 2 sec
        || ufixEqualWithinVariance(50.00000475, collectedAmount),       // time passed = secondsInYear + 3 sec
        message: "Insurance collected should be ~50.0 MOET")
}
