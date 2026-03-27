import Test
import BlockchainHelpers

import "test_helpers.cdc"
import "test_helpers_rebalance.cdc"
import "FlowALPRebalancerPaidv1"
import "FlowTransactionScheduler"
import "MOET"
import "FlowALPSupervisorv1"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) let protocolConsumerAccount = Test.getAccount(0x0000000000000008)
access(all) let userAccount = Test.createAccount()

access(all) let flowVaultStoragePath = /storage/flowTokenVault
access(all) let flowTokenIdentifier = "A.0000000000000003.FlowToken.Vault"

access(all) let positionStoragePath = /storage/position
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

    createPaidRebalancer(signer: protocolAccount, paidRebalancerAdminStoragePath: FlowALPRebalancerPaidv1.adminStoragePath)
    createPositionNotManaged(signer: userAccount, amount: 100.0, vaultStoragePath: flowVaultStoragePath, pushToDrawDownSink: false, positionStoragePath: positionStoragePath)
    depositToPositionNotManaged(signer: userAccount, positionStoragePath: positionStoragePath, amount: 100.0, vaultStoragePath: flowVaultStoragePath, pushToDrawDownSink: false)
    addPaidRebalancerToPosition(signer: userAccount, positionStoragePath: positionStoragePath)
    let evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.CreatedRebalancerPaid>())
    Test.assertEqual(1, evts.length) // one paid rebalancer created for the position
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
    var evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.Rebalanced>())
    Test.assertEqual(0, evts.length)

    Test.moveTime(by: 10.0)
    Test.commitBlock()
    evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.Rebalanced>())
    Test.assertEqual(1, evts.length)

    Test.moveTime(by: 90.0)
    Test.commitBlock()
    evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.Rebalanced>())
    Test.assertEqual(1, evts.length)

    Test.moveTime(by: 10.0)
    Test.commitBlock()
    evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.Rebalanced>())
    Test.assertEqual(2, evts.length)
}

access(all) fun test_delayed_rebalance() {
    // should execute every 100 seconds
    Test.moveTime(by: 1000.0)
    Test.commitBlock()
    var evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.Rebalanced>())
    Test.assertEqual(1, evts.length)

    Test.moveTime(by: 1.0)
    Test.commitBlock()

    // we do NOT expect more rebalances here!
    evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.Rebalanced>())
    Test.assertEqual(1, evts.length)

    Test.moveTime(by: 99.0)
    Test.commitBlock()

    evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.Rebalanced>())
    Test.assertEqual(2, evts.length)
}

access(all) fun test_fix_reschedule_idempotent() {
    let createdEvts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.CreatedRebalancerPaid>())
    Test.assertEqual(1, createdEvts.length)
    let created = createdEvts[0] as! FlowALPRebalancerPaidv1.CreatedRebalancerPaid

    // when initially created, it should emit a FixedReschedule event to get started
    var evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.FixedReschedule>())
    Test.assertEqual(1, evts.length)

    fixPaidReschedule(positionID: created.positionID)
    fixPaidReschedule(positionID: created.positionID)

    Test.moveTime(by: 10.0)
    Test.commitBlock()

    fixPaidReschedule(positionID: created.positionID)

    Test.moveTime(by: 1000.0)
    Test.commitBlock()

    fixPaidReschedule(positionID: created.positionID)
    fixPaidReschedule(positionID: created.positionID)

    evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.FixedReschedule>())
    Test.assertEqual(1, evts.length)
}

access(all) fun test_fix_reschedule_no_funds() {
    let createdEvts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.CreatedRebalancerPaid>())
    Test.assertEqual(1, createdEvts.length)
    let created = createdEvts[0] as! FlowALPRebalancerPaidv1.CreatedRebalancerPaid

    Test.moveTime(by: 100.0)
    Test.commitBlock()

    var evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.Rebalanced>())
    Test.assertEqual(1, evts.length)

    // drain the funding contract so the transaction reverts
    let balance = getBalance(address: protocolAccount.address, vaultPublicPath: /public/flowTokenBalance)!
    sendFlow(from: protocolAccount, to: userAccount, amount: balance)

    Test.moveTime(by: 100.0)
    Test.commitBlock()

    // it still executed once but should have no transaction scheduled
    evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.Rebalanced>())
    Test.assertEqual(2, evts.length)

    Test.moveTime(by: 1000.0)
    Test.commitBlock()
    evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.Rebalanced>())
    Test.assertEqual(2, evts.length)

    // now we fix the missing funds and call fix reschedule
    mintFlow(to: protocolAccount, amount: 1000.0)
    fixPaidReschedule(positionID: created.positionID)
    Test.moveTime(by: 1.0)
    Test.commitBlock()

    evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.Rebalanced>())
    Test.assertEqual(3, evts.length)

    evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.FixedReschedule>())
    Test.assertEqual(2, evts.length)
}

access(all) fun test_two_paid_rebalancers_same_position() {
    // One paid rebalancer is created in setup for the position.
    var evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.CreatedRebalancerPaid>())
    Test.assertEqual(1, evts.length)

    let addRes: Test.TransactionResult = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("./transactions/rebalancer/add_paid_rebalancer_to_position.cdc"),
        authorizers: [userAccount.address],
        signers: [userAccount],
        arguments: [positionStoragePath]
    ))
    // creating a second paid rebalancer for the same position must fail
    Test.expect(addRes, Test.beFailed())
    Test.assertError(addRes, errorMessage: "rebalancer already exists")

    evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.CreatedRebalancerPaid>())
    Test.assertEqual(1, evts.length)
}

access(all) fun test_change_recurring_config_as_user() {
    let evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.CreatedRebalancerPaid>())
    Test.assertEqual(1, evts.length)
    let e = evts[0] as! FlowALPRebalancerPaidv1.CreatedRebalancerPaid

    changePaidInterval(signer: userAccount, positionID: e.positionID, interval: 100, expectFailure: true)
}

access(all) fun test_change_recurring_config() {
    let createdEvts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.CreatedRebalancerPaid>())
    Test.assertEqual(1, createdEvts.length)
    let created = createdEvts[0] as! FlowALPRebalancerPaidv1.CreatedRebalancerPaid

    // Initial interval=100. First rebalance fires at T+100, schedules next at T+200.
    Test.moveTime(by: 100.0)
    Test.commitBlock()

    var evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.Rebalanced>())
    Test.assertEqual(1, evts.length)

    // Change to interval=1000. The already-scheduled tx at T+200 is NOT cancelled.
    changePaidInterval(signer: protocolAccount, positionID: created.positionID, interval: 1000, expectFailure: false)

    // T+200: old-interval tx fires; next is now scheduled at T+1200 (new interval=1000).
    Test.moveTime(by: 100.0)
    Test.commitBlock()
    evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.Rebalanced>())
    Test.assertEqual(2, evts.length)

    // T+1199: new interval not yet elapsed.
    Test.moveTime(by: 999.0)
    Test.commitBlock()
    evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.Rebalanced>())
    Test.assertEqual(2, evts.length)

    // T+1200: new interval fires.
    Test.moveTime(by: 1.0)
    Test.commitBlock()
    evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.Rebalanced>())
    Test.assertEqual(3, evts.length)
}

access(all) fun test_delete_rebalancer() {
    let createdEvts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.CreatedRebalancerPaid>())
    Test.assertEqual(1, createdEvts.length)
    let created = createdEvts[0] as! FlowALPRebalancerPaidv1.CreatedRebalancerPaid

    Test.moveTime(by: 100.0)
    Test.commitBlock()

    var evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.Rebalanced>())
    Test.assertEqual(1, evts.length)

    deletePaidRebalancer(signer: protocolAccount, positionID: created.positionID)

    Test.moveTime(by: 1000.0)
    Test.commitBlock()

    evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.Rebalanced>())
    Test.assertEqual(1, evts.length)
}

access(all) fun test_public_fix_reschedule() {
    Test.moveTime(by: 100.0)
    Test.commitBlock()

    var evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.Rebalanced>())
    Test.assertEqual(1, evts.length)
    let e = evts[0] as! FlowALPRebalancerPaidv1.Rebalanced

    fixPaidReschedule(positionID: e.positionID)
}

access(all) fun test_supervisor_executed() {
    Test.moveTime(by: 100.0)
    Test.commitBlock()

    var evts = Test.eventsOfType(Type<FlowALPSupervisorv1.Executed>())
    Test.assertEqual(1, evts.length)

    Test.moveTime(by: 60.0 * 60.0)
    Test.commitBlock()

    evts = Test.eventsOfType(Type<FlowALPSupervisorv1.Executed>())
    Test.assertEqual(2, evts.length)
}

/// Regression test for FLO-27: if a paid rebalancer is deleted without removing its UUID from
/// the Supervisor's set, the next Supervisor tick must NOT panic. Before the fix,
/// fixReschedule(uuid:) force-unwrapped borrowRebalancer(uuid)! which panicked on a stale UUID,
/// reverting the whole executeTransaction and blocking recovery for all other rebalancers.
access(all) fun test_supervisor_stale_uuid_does_not_panic() {
    // Get the positionID of the paid rebalancer created during setup.
    let createdEvts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.CreatedRebalancerPaid>())
    Test.assertEqual(1, createdEvts.length)
    let created = createdEvts[0] as! FlowALPRebalancerPaidv1.CreatedRebalancerPaid

    // Register the positionID with the Supervisor so it will call fixReschedule on it each tick.
    addPaidRebalancerToSupervisor(signer: userAccount, positionID: created.positionID, supervisorStoragePath: supervisorStoragePath)

    // Delete the paid rebalancer WITHOUT removing its positionID from the Supervisor — this leaves a
    // stale entry in the Supervisor's paidRebalancers set, simulating the FLO-27 bug scenario.
    deletePaidRebalancer(signer: protocolAccount, positionID: created.positionID)

    // Advance time to trigger the Supervisor's scheduled tick.
    Test.moveTime(by: 60.0 * 60.0 * 10.0)
    Test.commitBlock()

    // The Supervisor must have executed without panicking.
    let executedEvts = Test.eventsOfType(Type<FlowALPSupervisorv1.Executed>())
    Test.assert(executedEvts.length >= 2, message: "Supervisor should have executed at least 2 times (initial + stale prune)")

    // The stale positionID must have been pruned from the Supervisor's set.
    let removedEvts = Test.eventsOfType(Type<FlowALPSupervisorv1.RemovedPaidRebalancer>())
    Test.assertEqual(1, removedEvts.length)
    let removed = removedEvts[0] as! FlowALPSupervisorv1.RemovedPaidRebalancer
    Test.assertEqual(created.positionID, removed.positionID)

    // A second tick should not emit another RemovedPaidRebalancer — already cleaned up.
    Test.moveTime(by: 60.0 * 60.0)
    Test.commitBlock()
    let removedEvts2 = Test.eventsOfType(Type<FlowALPSupervisorv1.RemovedPaidRebalancer>())
    Test.assertEqual(1, removedEvts2.length)
}

access(all) fun test_supervisor() {
    Test.moveTime(by: 100.0)
    Test.commitBlock()

    var evts = Test.eventsOfType(Type<FlowALPSupervisorv1.Executed>())
    Test.assertEqual(1, evts.length)

    evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.Rebalanced>())
    Test.assertEqual(1, evts.length)
    let e = evts[0] as! FlowALPRebalancerPaidv1.Rebalanced

    addPaidRebalancerToSupervisor(signer: userAccount, positionID: e.positionID, supervisorStoragePath: supervisorStoragePath)

    // drain the funding contract so the transaction reverts
    let balance = getBalance(address: protocolAccount.address, vaultPublicPath: /public/flowTokenBalance)!
    sendFlow(from: protocolAccount, to: userAccount, amount: balance)

    Test.moveTime(by: 100.0)
    Test.commitBlock()

    // it still executed once but should have no transaction scheduled
    evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.Rebalanced>())
    Test.assertEqual(2, evts.length)

    Test.moveTime(by: 1000.0)
    Test.commitBlock()

    // now we fix the missing funds and call fix reschedule
    mintFlow(to: protocolAccount, amount: 1000.0)
    Test.moveTime(by: 60.0 * 100.0)
    Test.commitBlock()

    // now supervisor will fix the rebalancer
    evts = Test.eventsOfType(Type<FlowALPSupervisorv1.Executed>())
    Test.assert(evts.length >= 2, message: "Supervisor should have executed at least 2 times")

    evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.FixedReschedule>())
    Test.assertEqual(2, evts.length)

    Test.moveTime(by: 10.0)
    Test.commitBlock()

    // now rebalancer could run the transaction again
    evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.Rebalanced>())
    Test.assertEqual(3, evts.length)
}
