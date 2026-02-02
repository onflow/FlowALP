import Test
import BlockchainHelpers

import "test_helpers.cdc"
import "test_helpers_rebalance.cdc"
import "FlowCreditMarketRebalancerV1"
import "FlowTransactionScheduler"
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

access(all) fun test_fix_reschedule_idempotent() {
    safeReset()

    // when initially created, it should emit an fix reschedule event to get started
    var evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.FixReschedule>())
    Test.assertEqual(1, evts.length)

    fixPaidReschedule(signer: userAccount, uuid: nil)
    fixPaidReschedule(signer: userAccount, uuid: nil)

    Test.moveTime(by: 10.0)
    Test.commitBlock()

    fixPaidReschedule(signer: userAccount, uuid: nil)

    Test.moveTime(by: 1000.0)
    Test.commitBlock()

    fixPaidReschedule(signer: userAccount, uuid: nil)
    fixPaidReschedule(signer: userAccount, uuid: nil)

    evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.FixReschedule>())
    Test.assertEqual(1, evts.length)
}

access(all) fun test_fix_reschedule_no_funds() {
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

    // now we fix the missing funds and call fix reschedule
    mintFlow(to: protocolAccount, amount: 1000.0)
    fixPaidReschedule(signer: userAccount, uuid: nil)
    Test.moveTime(by: 1.0)
    Test.commitBlock()

    evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(3, evts.length)

    evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.FixReschedule>())
    Test.assertEqual(2, evts.length)
}

access(all) fun test_change_recurring_config_as_user() {
    safeReset()

    var evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.CreatedRebalancer>())
    Test.assertEqual(1, evts.length)
    let e = evts[0] as! FlowCreditMarketRebalancerV1.CreatedRebalancer

    changePaidInterval(signer: userAccount, uuid: e.uuid, interval: 100, expectFailure: true)
}

access(all) fun test_change_recurring_config() {
    safeReset()

    Test.moveTime(by: 150.0)
    Test.commitBlock()

    var evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(1, evts.length)
    let e = evts[0] as! FlowCreditMarketRebalancerV1.Rebalanced

    changePaidInterval(signer: protocolAccount, uuid: e.uuid, interval: 1000, expectFailure: false)

    Test.moveTime(by: 980.0)
    Test.commitBlock()

    evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(1, evts.length)

    Test.moveTime(by: 20.0)
    Test.commitBlock()

    evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(2, evts.length)

    changePaidInterval(signer: protocolAccount, uuid: e.uuid, interval: 50, expectFailure: false)

    Test.moveTime(by: 45.0)
    Test.commitBlock()

    evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(2, evts.length)

    Test.moveTime(by: 5.0)
    Test.commitBlock()

    evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(3, evts.length)
}

access(all) fun test_delete_rebalancer() {
    safeReset()

    Test.moveTime(by: 100.0)
    Test.commitBlock()

    var evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(1, evts.length)

    deletePaidRebalancer(signer: userAccount)

    Test.moveTime(by: 1000.0)
    Test.commitBlock()

    evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(1, evts.length)
}

access(all) fun test_public_fix_reschedule() {
    safeReset()

    Test.moveTime(by: 100.0)
    Test.commitBlock()

    var evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(1, evts.length)
    let e = evts[0] as! FlowCreditMarketRebalancerV1.Rebalanced
    let publicPath = PublicPath(identifier: "paidRebalancerV1\(e.uuid)")!

    let randomAccount = Test.createAccount()
    fixPaidReschedule(signer: randomAccount, uuid: e.uuid)
}