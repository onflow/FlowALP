import Test
import BlockchainHelpers

import "test_helpers.cdc"
import "test_helpers_rebalance.cdc"
import "FlowCreditMarketRebalancerV1"
import "FlowCreditMarketRebalancerPaidV1"
import "FlowTransactionScheduler"
import "MOET"
import "FlowCreditMarketSupervisorV1"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) let protocolConsumerAccount = Test.getAccount(0x0000000000000008)
access(all) let userAccount = Test.createAccount()

access(all) let flowVaultStoragePath = /storage/flowTokenVault
access(all) let flowTokenIdentifier = "A.0000000000000003.FlowToken.Vault"

access(all) let positionStoragePath = /storage/position
access(all) let paidRebalancerStoragePath = /storage/paidRebalancer
access(all) let supervisorStoragePath = /storage/supervisor
access(all) let cronHandlerStoragePath = /storage/myRecurringTaskHandler

access(all) var snapshot: UInt64 = 0

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

    createPaidRebalancer(signer: protocolAccount, paidRebalancerAdminStoragePath: FlowCreditMarketRebalancerPaidV1.adminStoragePath)
    createPositionNotManaged(signer: userAccount, amount: 100.0, vaultStoragePath: flowVaultStoragePath, pushToDrawDownSink: false, positionStoragePath: positionStoragePath)
    depositToPositionNotManaged(signer: userAccount, positionStoragePath: positionStoragePath, amount: 100.0, vaultStoragePath: flowVaultStoragePath, pushToDrawDownSink: false)
    addPaidRebalancerToPosition(signer: userAccount, positionStoragePath: positionStoragePath, paidRebalancerStoragePath: paidRebalancerStoragePath)
    let evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.CreatedRebalancer>())
    let paidRebalancerUUID = evts[0] as! FlowCreditMarketRebalancerV1.CreatedRebalancer
    createSupervisor(
        signer: userAccount, 
        cronExpression: "0 * * * *",
        cronHandlerStoragePath: cronHandlerStoragePath,
        keeperExecutionEffort: 1000,
        executorExecutionEffort: 1000,
        supervisorStoragePath: supervisorStoragePath
    )
    
    snapshot = getCurrentBlockHeight()
}

access(all) fun beforeEach() {
    if getCurrentBlockHeight() > snapshot {
        Test.reset(to: snapshot)
    }
}

access(all) fun test_on_time() {
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
    // when initially created, it should emit an fix reschedule event to get started
    var evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.FixedReschedule>())
    Test.assertEqual(1, evts.length)

    fixPaidReschedule(signer: userAccount, uuid: nil, paidRebalancerStoragePath: paidRebalancerStoragePath)
    fixPaidReschedule(signer: userAccount, uuid: nil, paidRebalancerStoragePath: paidRebalancerStoragePath)

    Test.moveTime(by: 10.0)
    Test.commitBlock()

    fixPaidReschedule(signer: userAccount, uuid: nil, paidRebalancerStoragePath: paidRebalancerStoragePath)

    Test.moveTime(by: 1000.0)
    Test.commitBlock()

    fixPaidReschedule(signer: userAccount, uuid: nil, paidRebalancerStoragePath: paidRebalancerStoragePath)
    fixPaidReschedule(signer: userAccount, uuid: nil, paidRebalancerStoragePath: paidRebalancerStoragePath)

    evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.FixedReschedule>())
    Test.assertEqual(1, evts.length)
}

access(all) fun test_fix_reschedule_no_funds() {
    Test.moveTime(by: 100.0)
    Test.commitBlock()

    var evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(1, evts.length)

    // drain the funding contract so the transaction reverts
    let balance = getBalance(address: protocolAccount.address, vaultPublicPath: /public/flowTokenBalance)!
    sendFlow(from: protocolAccount, to: userAccount, amount: balance)

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
    fixPaidReschedule(signer: userAccount, uuid: nil, paidRebalancerStoragePath: paidRebalancerStoragePath)
    Test.moveTime(by: 1.0)
    Test.commitBlock()

    evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(3, evts.length)

    evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.FixedReschedule>())
    Test.assertEqual(2, evts.length)
}

access(all) fun test_change_recurring_config_as_user() {
    var evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.CreatedRebalancer>())
    Test.assertEqual(1, evts.length)
    let e = evts[0] as! FlowCreditMarketRebalancerV1.CreatedRebalancer

    changePaidInterval(signer: userAccount, uuid: e.uuid, interval: 100, expectFailure: true)
}

access(all) fun test_change_recurring_config() {
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
    Test.moveTime(by: 100.0)
    Test.commitBlock()

    var evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(1, evts.length)

    deletePaidRebalancer(signer: userAccount, paidRebalancerStoragePath: paidRebalancerStoragePath)

    Test.moveTime(by: 1000.0)
    Test.commitBlock()

    evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(1, evts.length)
}

access(all) fun test_public_fix_reschedule() {
    Test.moveTime(by: 100.0)
    Test.commitBlock()

    var evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(1, evts.length)
    let e = evts[0] as! FlowCreditMarketRebalancerV1.Rebalanced

    let randomAccount = Test.createAccount()
    fixPaidReschedule(signer: randomAccount, uuid: e.uuid, paidRebalancerStoragePath: paidRebalancerStoragePath)
}

access(all) fun test_supervisor_executed() {
    Test.moveTime(by: 100.0)
    Test.commitBlock()

    var evts = Test.eventsOfType(Type<FlowCreditMarketSupervisorV1.Executed>())
    Test.assertEqual(1, evts.length)

    Test.moveTime(by: 60.0 * 60.0)
    Test.commitBlock()

    evts = Test.eventsOfType(Type<FlowCreditMarketSupervisorV1.Executed>())
    Test.assertEqual(2, evts.length)
}

access(all) fun test_supervisor() {
    Test.moveTime(by: 100.0)
    Test.commitBlock()

    var evts = Test.eventsOfType(Type<FlowCreditMarketSupervisorV1.Executed>())
    Test.assertEqual(1, evts.length)

    evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(1, evts.length)
    let e = evts[0] as! FlowCreditMarketRebalancerV1.Rebalanced

    addPaidRebalancerToSupervisor(signer: userAccount, uuid: e.uuid, supervisorStoragePath: supervisorStoragePath)

    // drain the funding contract so the transaction reverts
    let balance = getBalance(address: protocolAccount.address, vaultPublicPath: /public/flowTokenBalance)!
    sendFlow(from: protocolAccount, to: userAccount, amount: balance)

    Test.moveTime(by: 100.0)
    Test.commitBlock()

    // it still executed once but should have no transaction scheduled
    evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(2, evts.length)

    Test.moveTime(by: 1000.0)
    Test.commitBlock()

    // now we fix the missing funds and call fix reschedule
    mintFlow(to: protocolAccount, amount: 1000.0)
    Test.moveTime(by: 60.0* 100.0)
    Test.commitBlock()

    // now supervisor will fix the rebalancer
    evts = Test.eventsOfType(Type<FlowCreditMarketSupervisorV1.Executed>())
    Test.assert(evts.length >= 2, message: "Supervisor should have executed at least 2 times")

    evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.FixedReschedule>())
    Test.assertEqual(2, evts.length)

    Test.moveTime(by: 10.0)
    Test.commitBlock()

    // now rebalancer could run the transaction again
    evts = Test.eventsOfType(Type<FlowCreditMarketRebalancerV1.Rebalanced>())
    Test.assertEqual(3, evts.length)
}