import Test
import BlockchainHelpers

import "test_helpers.cdc"
import "test_helpers_rebalance.cdc"
import "FlowCreditMarketRebalancerV1"
import "MOET"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) let protocolConsumerAccount = Test.getAccount(0x0000000000000008)
access(all) let userAccount = Test.createAccount()

access(all) let flowVaultStoragePath = /storage/flowTokenVault
access(all) let flowTokenIdentifier = "A.0000000000000003.FlowToken.Vault"
access(all) let moetTokenIdentifier = "A.0000000000000007.MOET.Vault"
access(all) var snapshot: UInt64 = 0
access(all) let hourInSeconds = 3600.0

access(all) fun safeReset() {
    let cur = getCurrentBlockHeight()
    if cur > snapshot {
        Test.reset(to: snapshot)
    }
}

access(all) fun setup() {
    deployContracts()

    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)
    addSupportedTokenZeroRateCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )
    setupMoetVault(userAccount, beFailed: false)
    mintFlow(to: userAccount, amount: 1000.0)
    mintFlow(to: protocolAccount, amount: 1000.0)

    grantPoolCapToConsumer()

    createPaidRebalancer(signer: protocolAccount)
    createWrappedPosition(signer: userAccount, amount: 100.0, vaultStoragePath: flowVaultStoragePath, pushToDrawDownSink: false)
    depositToWrappedPosition(signer: userAccount, amount: 100.0, vaultStoragePath: flowVaultStoragePath, pushToDrawDownSink: false)
    addPaidRebalancerToWrappedPosition(signer: userAccount)
    
    snapshot = getCurrentBlockHeight()
}

access(all) fun test_on_time() {
    safeReset()



    // should execute every 100 seconds
    Test.moveTime(by: 90.0)
    Test.commitBlock()
    var evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(0, evts.length)

    Test.moveTime(by: 10.0)
    Test.commitBlock()
    evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(1, evts.length)

    Test.moveTime(by: 90.0)
    Test.commitBlock()
    evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(1, evts.length)

    Test.moveTime(by: 10.0)
    Test.commitBlock()
    evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(2, evts.length)
}

access(all) fun test_delayed_rebalance() {
    safeReset()

    // should execute every 100 seconds
    Test.moveTime(by: 1000.0)
    Test.commitBlock()
    var evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(1, evts.length)

    Test.moveTime(by: 1.0)
    Test.commitBlock()

    // we do NOT expect more rebalances here!
    evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(1, evts.length)

    Test.moveTime(by: 99.0)
    Test.commitBlock()

    evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(2, evts.length)
}

access(all) fun test_unstuck_idempotent() {
    safeReset()

    // when initially created, it should emit an unstuck event to get started
    var evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Unstuck>())
    Test.assertEqual(1, evts.length)

    unstuck(signer: userAccount)
    unstuck(signer: userAccount)

    Test.moveTime(by: 10.0)
    Test.commitBlock()

    unstuck(signer: userAccount)

    Test.moveTime(by: 1000.0)
    Test.commitBlock()

    unstuck(signer: userAccount)
    unstuck(signer: userAccount)

    evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Unstuck>())
    Test.assertEqual(1, evts.length)
}

access(all) fun test_unstuck_no_funds() {
    safeReset()

    Test.moveTime(by: 100.0)
    Test.commitBlock()

    var evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(1, evts.length)

    // drain the funding contract so the transaction reverts
    let balance = getBalance(address: protocolAccount.address, vaultPublicPath: /public/flowTokenBalance)!
    actuallyTransferFlowTokens(from: protocolAccount, to: userAccount, amount: balance)

    Test.moveTime(by: 100.0)
    Test.commitBlock()

    // it still executed once but should have no transaction scheduled
    evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(2, evts.length)

    Test.moveTime(by: 1000.0)
    Test.commitBlock()
    evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(2, evts.length)

    // now we fix the missing funds and call unstuck
    mintFlow(to: protocolAccount, amount: 1000.0)
    unstuck(signer: userAccount)
    Test.moveTime(by: 1.0)
    Test.commitBlock()

    evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(3, evts.length)

    evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Unstuck>())
    Test.assertEqual(2, evts.length)
}

// TODO(holyfuchs): still need to implement this test
access(all) fun test_change_recurring_config() {
    safeReset()
    // change config see that all of them reschedule
}

// TODO(holyfuchs): still need to implement this test
access(all) fun test_delete_rebalancer() {
    safeReset()
    // remove rebalancer resource check it doesn't execute anymore
}