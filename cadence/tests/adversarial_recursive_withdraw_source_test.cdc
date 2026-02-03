import Test
import BlockchainHelpers

import "MOET"
import "FlowCreditMarket"
import "DeFiActions"
import "DeFiActionsUtils"
import "FlowToken"
import "test_helpers.cdc"
import "FungibleToken"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) let protocolConsumerAccount = Test.getAccount(0x0000000000000008)
access(all) let userAccount = Test.createAccount()

access(all) let flowTokenIdentifier = "A.0000000000000003.FlowToken.Vault"
access(all) let moetTokenIdentifier = "A.0000000000000007.MOET.Vault"
access(all) let flowVaultStoragePath = /storage/flowTokenVault
access(all) let wrapperStoragePath = /storage/flowCreditMarketPositionWrapper

access(all) let flowBorrowFactor = 1.0
access(all) let flowStartPrice = 1.0
access(all) let positionFundingAmount = 1_000.0

access(all) var snapshot: UInt64 = 0
access(all) var positionID: UInt64 = 0

access(all)
fun setup() {
    deployContracts()

    let betaTxResult = grantBeta(protocolAccount, protocolConsumerAccount)
    Test.expect(betaTxResult, Test.beSucceeded())

    // Price setup
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: flowStartPrice)
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: moetTokenIdentifier, price: 1.0)

    // Create the Pool & add FLOW as supported token
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: moetTokenIdentifier, beFailed: false)
    addSupportedTokenZeroRateCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.65,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // Prep user's account
    setupMoetVault(userAccount, beFailed: false)
    mintFlow(to: userAccount, amount: positionFundingAmount * 2.0)

    snapshot = getCurrentBlockHeight()
}

access(all)
fun testRecursiveWithdrawSource() {
    if snapshot < getCurrentBlockHeight() {
        Test.reset(to: snapshot)
    }

    // Setup user 1 - Giving pool 10000 Flow to borrow
    let user1 = Test.createAccount()
    setupMoetVault(user1, beFailed: false)
    mintMoet(signer: protocolAccount, to: user1.address, amount: 10000.0, beFailed: false)
    mintFlow(to: user1, amount: 10000.0)
    grantPoolCapToConsumer()
    
    let initialDeposit1 = 10000.0
    createWrappedPosition(signer: user1, amount: initialDeposit1, vaultStoragePath: /storage/flowTokenVault, pushToDrawDownSink: false)
    log("[TEST] USER1 POSITION ID: \(positionID)")
    
    // ==============================

    // Open a position with pushToDrawDownSink=true to get some MOET borrowed
    let openRes = executeTransaction(
        "./transactions/mock-flow-credit-market-consumer/create_wrapped_position_hack.cdc",
        [positionFundingAmount, flowVaultStoragePath, false],
        userAccount
    )
    Test.expect(openRes, Test.beSucceeded())

    // Get position ID from events
    var evts = Test.eventsOfType(Type<FlowCreditMarket.Opened>())
    let openedEvt = evts[evts.length - 1] as! FlowCreditMarket.Opened
    positionID = openedEvt.pid
    log("[TEST] Position opened with ID: \(positionID)")

    let remainingFlow = getBalance(address: userAccount.address, vaultPublicPath: /public/flowTokenReceiver) ?? 0.0
    log("[TEST] Remaining Flow: \(remainingFlow)")
    let moetBalance = getBalance(address: userAccount.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0
    log("[TEST] Remaining MOET: \(moetBalance)")

    // put 1000 Flow into the position
    // somehow only 650 get put into it?
    // took 500 out of the position

    let withdrawRes = executeTransaction(
        "./transactions/flow-credit-market/pool-management/withdraw_from_position.cdc",
        [positionID, flowTokenIdentifier, 1500.0, true], // pullFromTopUpSource: true
        userAccount
    )
    Test.expect(withdrawRes, Test.beFailed())

    let currentFlow = getBalance(address: userAccount.address, vaultPublicPath: /public/flowTokenReceiver) ?? 0.0
    log("[TEST] Current Flow: \(currentFlow)")
    let currentMoet = getBalance(address: userAccount.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0
    log("[TEST] Current MOET: \(currentMoet)")




    // let withdrawRes2 = executeTransaction(
    //     "./transactions/flow-credit-market/pool-management/withdraw_from_position.cdc",
    //     [positionID, flowTokenIdentifier, 10000.0, false], // pullFromTopUpSource: true
    //     user1
    // )
    // Test.expect(withdrawRes2, Test.beSucceeded())
    // log("[TEST] Withdrawal 2 succeeded")

    // log info about the position
    // log("[TEST] Position info: \(getPositionInfo(pid: positionID, beFailed: false))")

    // // Get initial available balance without topUpSource
    // let initialAvailable = getAvailableBalance(
    //     pid: positionID,
    //     vaultIdentifier: moetTokenIdentifier,
    //     pullFromTopUpSource: false,
    //     beFailed: false
    // )
    // log("[TEST] Initial available balance (no topUp): \(initialAvailable)")

    // // Calculate a withdrawal amount that will require topUpSource
    // // We need to withdraw more than what's available without topUpSource
    // let largeWithdrawAmount = initialAvailable * 1.00000001
    // // let largeWithdrawAmount = 110.0
    // log("[TEST] Large withdrawal amount (requires topUp): \(largeWithdrawAmount)")

    // // Calculate a smaller withdrawal amount that does NOT require topUpSource
    // // This should be less than the available balance
    // let smallWithdrawAmount = initialAvailable * 0.3
    // log("[TEST] Small withdrawal amount (no topUp needed): \(smallWithdrawAmount)")

    // // Verify that the large amount requires topUpSource (when topUpSource provides MOET)
    // let requiredForLarge = fundsRequiredForTargetHealthAfterWithdrawing(
    //     pid: positionID,
    //     depositType: flowTokenIdentifier,
    //     targetHealth: UFix128(minHealth),
    //     withdrawType: moetTokenIdentifier,
    //     withdrawAmount: largeWithdrawAmount,
    //     beFailed: false
    // )
    // log("[TEST] Required deposit for large withdrawal (with MOET topUp): \(requiredForLarge)")
    // Test.assert(requiredForLarge > 0.0, message: "Large withdrawal should require topUpSource")

    // // Verify that the small amount does NOT require topUpSource
    // let requiredForSmall = fundsRequiredForTargetHealthAfterWithdrawing(
    //     pid: positionID,
    //     depositType: flowTokenIdentifier,
    //     targetHealth: UFix128(minHealth),
    //     withdrawType: moetTokenIdentifier,
    //     withdrawAmount: smallWithdrawAmount,
    //     beFailed: false
    // )
    // log("[TEST] Required deposit for small withdrawal: \(requiredForSmall)")
    // Test.assert(requiredForSmall == 0.0, message: "Small withdrawal should NOT require topUpSource")
    
    // // Also check what would be required if topUpSource provides Flow (for our recursive source)
    // let requiredForLargeWithFlow = fundsRequiredForTargetHealthAfterWithdrawing(
    //     pid: positionID,
    //     depositType: flowTokenIdentifier,
    //     targetHealth: UFix128(minHealth),
    //     withdrawType: moetTokenIdentifier,
    //     withdrawAmount: largeWithdrawAmount,
    //     beFailed: false
    // )
    // log("[TEST] Required deposit for large withdrawal (with Flow topUp): \(requiredForLargeWithFlow)")

    // // Ensure user has enough Flow in their vault for the topUpSource
    // // The user should have some Flow remaining after opening the position
    // let userFlowBalance = getBalance(address: userAccount.address, vaultPublicPath: /public/flowTokenReceiver) ?? 0.0
    // log("[TEST] User Flow balance: \(userFlowBalance)")
    
    // // Ensure user has enough Flow for the topUpSource (we need Flow, not MOET, since our source provides Flow)
    // // Mint additional Flow if needed
    // if userFlowBalance < requiredForLargeWithFlow {
    //     let additionalFlow = requiredForLargeWithFlow - userFlowBalance + 100.0  // Add buffer
    //     mintFlow(to: userAccount, amount: additionalFlow)
    //     log("[TEST] Minted \(additionalFlow) Flow to user")
    // }

    // // Now make a withdrawal with the large amount that requires pullFromTopUpSource
    // // This should trigger the recursive source's withdrawAvailable, which will
    // // call withdrawAndPull with the small amount (without pullFromTopUpSource)
    // // log("[TEST] Making large withdrawal that requires topUpSource...")
    
    // let withdrawRes = executeTransaction(
    //     "./transactions/flow-credit-market/pool-management/withdraw_from_position.cdc",
    //     [positionID, moetTokenIdentifier, largeWithdrawAmount, true], // pullFromTopUpSource: true
    //     userAccount
    // )
    
    // // The transaction should succeed because:
    // // 1. withdrawAndPull is called with largeWithdrawAmount and pullFromTopUpSource: true
    // // 2. This triggers the recursive source's withdrawAvailable
    // // 3. The recursive source calls withdrawAndPull with smallWithdrawAmount and pullFromTopUpSource: false
    // // 4. This nested call succeeds because smallWithdrawAmount doesn't require topUpSource
    
    // Test.expect(withdrawRes, Test.beSucceeded())
    // log("[TEST] Large withdrawal succeeded with recursive source")

    // // Verify the position health is still above minimum
    let finalHealth = getPositionHealth(pid: positionID, beFailed: false)
    log("[TEST] Final position health: \(finalHealth)")
    // Test.assert(finalHealth >= UFix128(minHealth), message: "Position health should be at or above minimum")

    // log("==============================")
}
