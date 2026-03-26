import Test
import BlockchainHelpers

import "test_helpers.cdc"
import "test_helpers_rebalance.cdc"
import "FlowALPRebalancerv1"
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
access(all) let paidRebalancerStoragePath = /storage/paidRebalancer
access(all) let paidRebalancer2StoragePath = /storage/paidRebalancer2
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
    addPaidRebalancerToPosition(signer: userAccount, positionStoragePath: positionStoragePath, paidRebalancerStoragePath: paidRebalancerStoragePath)
    let evts = Test.eventsOfType(Type<FlowALPRebalancerv1.CreatedRebalancer>())
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
    var evts = Test.eventsOfType(Type<FlowALPRebalancerv1.Rebalanced>())
    Test.assertEqual(0, evts.length)

    Test.moveTime(by: 10.0)
    Test.commitBlock()
    evts = Test.eventsOfType(Type<FlowALPRebalancerv1.Rebalanced>())
    Test.assertEqual(1, evts.length)

    Test.moveTime(by: 90.0)
    Test.commitBlock()
    evts = Test.eventsOfType(Type<FlowALPRebalancerv1.Rebalanced>())
    Test.assertEqual(1, evts.length)

    Test.moveTime(by: 10.0)
    Test.commitBlock()
    evts = Test.eventsOfType(Type<FlowALPRebalancerv1.Rebalanced>())
    Test.assertEqual(2, evts.length)
}

access(all) fun test_delayed_rebalance() {
    // should execute every 100 seconds
    Test.moveTime(by: 1000.0)
    Test.commitBlock()
    var evts = Test.eventsOfType(Type<FlowALPRebalancerv1.Rebalanced>())
    Test.assertEqual(1, evts.length)

    Test.moveTime(by: 1.0)
    Test.commitBlock()

    // we do NOT expect more rebalances here!
    evts = Test.eventsOfType(Type<FlowALPRebalancerv1.Rebalanced>())
    Test.assertEqual(1, evts.length)

    Test.moveTime(by: 99.0)
    Test.commitBlock()

    evts = Test.eventsOfType(Type<FlowALPRebalancerv1.Rebalanced>())
    Test.assertEqual(2, evts.length)
}

access(all) fun test_fix_reschedule_idempotent() {
    // when initially created, it should emit an fix reschedule event to get started
    var evts = Test.eventsOfType(Type<FlowALPRebalancerv1.FixedReschedule>())
    Test.assertEqual(1, evts.length)

    fixPaidReschedule(signer: userAccount, positionID: nil, paidRebalancerStoragePath: paidRebalancerStoragePath)
    fixPaidReschedule(signer: userAccount, positionID: nil, paidRebalancerStoragePath: paidRebalancerStoragePath)

    Test.moveTime(by: 10.0)
    Test.commitBlock()

    fixPaidReschedule(signer: userAccount, positionID: nil, paidRebalancerStoragePath: paidRebalancerStoragePath)

    Test.moveTime(by: 1000.0)
    Test.commitBlock()

    fixPaidReschedule(signer: userAccount, positionID: nil, paidRebalancerStoragePath: paidRebalancerStoragePath)
    fixPaidReschedule(signer: userAccount, positionID: nil, paidRebalancerStoragePath: paidRebalancerStoragePath)

    evts = Test.eventsOfType(Type<FlowALPRebalancerv1.FixedReschedule>())
    Test.assertEqual(1, evts.length)
}

access(all) fun test_fix_reschedule_no_funds() {
    Test.moveTime(by: 100.0)
    Test.commitBlock()

    var evts = Test.eventsOfType(Type<FlowALPRebalancerv1.Rebalanced>())
    Test.assertEqual(1, evts.length)

    // drain the funding contract so the transaction reverts
    let balance = getBalance(address: protocolAccount.address, vaultPublicPath: /public/flowTokenBalance)!
    sendFlow(from: protocolAccount, to: userAccount, amount: balance)

    Test.moveTime(by: 100.0)
    Test.commitBlock()

    // it still executed once but should have no transaction scheduled
    evts = Test.eventsOfType(Type<FlowALPRebalancerv1.Rebalanced>())
    Test.assertEqual(2, evts.length)

    Test.moveTime(by: 1000.0)
    Test.commitBlock()
    evts = Test.eventsOfType(Type<FlowALPRebalancerv1.Rebalanced>())
    Test.assertEqual(2, evts.length)

    // now we fix the missing funds and call fix reschedule
    mintFlow(to: protocolAccount, amount: 1000.0)
    fixPaidReschedule(signer: userAccount, positionID: nil, paidRebalancerStoragePath: paidRebalancerStoragePath)
    Test.moveTime(by: 1.0)
    Test.commitBlock()

    evts = Test.eventsOfType(Type<FlowALPRebalancerv1.Rebalanced>())
    Test.assertEqual(3, evts.length)

    evts = Test.eventsOfType(Type<FlowALPRebalancerv1.FixedReschedule>())
    Test.assertEqual(2, evts.length)
}

// FLO-17 regression: when setRecurringConfig is called, cancel must use the OLD config's funder
// so that pre-paid fees are refunded to the original payer, not the new funder.
access(all) fun test_flo17_refund_goes_to_old_funder_not_new_funder() {
    // The rebalancer was created in setup() with protocolAccount as the txFunder.
    // A scheduled transaction with fees pre-paid from protocolAccount already exists.
    let createdEvts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.CreatedRebalancerPaid>())
    Test.assertEqual(1, createdEvts.length)
    let e = createdEvts[0] as! FlowALPRebalancerPaidv1.CreatedRebalancerPaid

    // Create a new funder account — this should NOT receive the refund for previously paid fees.
    let newFunderAccount = Test.createAccount()
    let _ = mintFlow(to: newFunderAccount, amount: 100.0)

    let oldFunderBalanceBefore = getBalance(address: protocolAccount.address, vaultPublicPath: /public/flowTokenBalance)!
    let newFunderBalanceBefore = getBalance(address: newFunderAccount.address, vaultPublicPath: /public/flowTokenBalance)!

    // Switch the recurring config to use newFunderAccount as the fee payer going forward.
    // This calls setRecurringConfig, which cancels the existing scheduled tx and refunds its fee.
    changePaidFunder(
        adminSigner: protocolAccount,
        newFunderSigner: newFunderAccount,
        positionID: e.positionID,
        interval: 100,
        expectFailure: false
    )

    let oldFunderBalanceAfter = getBalance(address: protocolAccount.address, vaultPublicPath: /public/flowTokenBalance)!
    let newFunderBalanceAfter = getBalance(address: newFunderAccount.address, vaultPublicPath: /public/flowTokenBalance)!

    // The pre-paid fee must be refunded to the OLD funder (protocolAccount), not the new one.
    Test.assert(
        oldFunderBalanceAfter > oldFunderBalanceBefore,
        message: "FLO-17: old funder should receive refund on config change, balance before=\(oldFunderBalanceBefore) after=\(oldFunderBalanceAfter)"
    )
    // New funder must not receive a windfall
    Test.assert(newFunderBalanceBefore >= newFunderBalanceAfter)
}

access(all) fun test_two_paid_rebalancers_same_position() {
    // One paid rebalancer is created in setup for the position.
    var evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.CreatedRebalancerPaid>())
    Test.assertEqual(1, evts.length)

    let addRes: Test.TransactionResult = _executeTransaction(
        "./transactions/rebalancer/add_paid_rebalancer_to_position.cdc",
        [positionStoragePath, paidRebalancer2StoragePath],
        userAccount
    )
    // creating a second paid rebalancer should fail
    Test.expect(addRes, Test.beFailed())
    Test.assertError(addRes, errorMessage: "rebalancer already exists")

    evts = Test.eventsOfType(Type<FlowALPRebalancerPaidv1.CreatedRebalancerPaid>())
    Test.assertEqual(1, evts.length)
}

access(all) fun test_change_recurring_config_as_user() {
    var evts = Test.eventsOfType(Type<FlowALPRebalancerv1.CreatedRebalancer>())
    Test.assertEqual(1, evts.length)
    let e = evts[0] as! FlowALPRebalancerv1.CreatedRebalancer

    changePaidInterval(signer: userAccount, positionID: e.positionID, interval: 100, expectFailure: true)
}

access(all) fun test_change_recurring_config() {
    Test.moveTime(by: 150.0)
    Test.commitBlock()

    var evts = Test.eventsOfType(Type<FlowALPRebalancerv1.Rebalanced>())
    Test.assertEqual(1, evts.length)
    let e = evts[0] as! FlowALPRebalancerv1.Rebalanced

    changePaidInterval(signer: protocolAccount, positionID: e.positionID, interval: 1000, expectFailure: false)

    Test.moveTime(by: 980.0)
    Test.commitBlock()

    evts = Test.eventsOfType(Type<FlowALPRebalancerv1.Rebalanced>())
    Test.assertEqual(1, evts.length)

    Test.moveTime(by: 20.0)
    Test.commitBlock()

    evts = Test.eventsOfType(Type<FlowALPRebalancerv1.Rebalanced>())
    Test.assertEqual(2, evts.length)

    changePaidInterval(signer: protocolAccount, positionID: e.positionID, interval: 50, expectFailure: false)

    Test.moveTime(by: 45.0)
    Test.commitBlock()

    evts = Test.eventsOfType(Type<FlowALPRebalancerv1.Rebalanced>())
    Test.assertEqual(2, evts.length)

    Test.moveTime(by: 5.0)
    Test.commitBlock()

    evts = Test.eventsOfType(Type<FlowALPRebalancerv1.Rebalanced>())
    Test.assertEqual(3, evts.length)
}

access(all) fun test_delete_rebalancer() {
    Test.moveTime(by: 100.0)
    Test.commitBlock()

    var evts = Test.eventsOfType(Type<FlowALPRebalancerv1.Rebalanced>())
    Test.assertEqual(1, evts.length)

    deletePaidRebalancer(signer: userAccount, paidRebalancerStoragePath: paidRebalancerStoragePath)

    Test.moveTime(by: 1000.0)
    Test.commitBlock()

    evts = Test.eventsOfType(Type<FlowALPRebalancerv1.Rebalanced>())
    Test.assertEqual(1, evts.length)
}

access(all) fun test_public_fix_reschedule() {
    Test.moveTime(by: 100.0)
    Test.commitBlock()

    var evts = Test.eventsOfType(Type<FlowALPRebalancerv1.Rebalanced>())
    Test.assertEqual(1, evts.length)
    let e = evts[0] as! FlowALPRebalancerv1.Rebalanced

    let randomAccount = Test.createAccount()
    fixPaidReschedule(signer: randomAccount, positionID: e.positionID, paidRebalancerStoragePath: paidRebalancerStoragePath)
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
    // Let the initial cron tick fire first (supervisor set is empty, so it does nothing
    // except emit Executed). This avoids a race where the cron fires during the add/delete
    // transactions below before the stale state is set up.
    Test.moveTime(by: 100.0)
    Test.commitBlock()

    let initialExecutedEvts = Test.eventsOfType(Type<FlowALPSupervisorv1.Executed>())
    Test.assert(initialExecutedEvts.length >= 1, message: "Initial cron tick should have fired")

    // Get the UUID of the paid rebalancer created during setup.
    let createdEvts = Test.eventsOfType(Type<FlowALPRebalancerv1.CreatedRebalancer>())
    Test.assertEqual(1, createdEvts.length)
    let created = createdEvts[0] as! FlowALPRebalancerv1.CreatedRebalancer

    // Register the UUID with the Supervisor so it will call fixReschedule on it each tick.
    addPaidRebalancerToSupervisor(signer: userAccount, positionID: created.positionID, supervisorStoragePath: supervisorStoragePath)

    // Delete the paid rebalancer WITHOUT removing its UUID from the Supervisor — this leaves a
    // stale UUID in the Supervisor's paidRebalancers set, simulating the FLO-27 bug scenario.
    deletePaidRebalancer(signer: userAccount, paidRebalancerStoragePath: paidRebalancerStoragePath)

    // Advance time to trigger the next Supervisor tick.
    Test.moveTime(by: 60.0 * 60.0)
    Test.commitBlock()

    // The Supervisor must have executed without panicking. If fixReschedule force-unwrapped
    // the missing rebalancer the entire transaction would revert and Executed would not be emitted.
    let executedEvts = Test.eventsOfType(Type<FlowALPSupervisorv1.Executed>())
    Test.assert(executedEvts.length >= 2, message: "Supervisor should have executed at least 2 times (initial + stale prune)")

    // The stale UUID must have been pruned from the Supervisor's set.
    let removedEvts = Test.eventsOfType(Type<FlowALPSupervisorv1.RemovedPaidRebalancer>())
    Test.assertEqual(1, removedEvts.length)
    let removed = removedEvts[0] as! FlowALPSupervisorv1.RemovedPaidRebalancer
    Test.assertEqual(created.positionID, removed.positionID)

    // A second tick should not emit another RemovedPaidRebalancer — the UUID was already cleaned up.
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

    evts = Test.eventsOfType(Type<FlowALPRebalancerv1.Rebalanced>())
    Test.assertEqual(1, evts.length)
    let e = evts[0] as! FlowALPRebalancerv1.Rebalanced

    addPaidRebalancerToSupervisor(signer: userAccount, positionID: e.positionID, supervisorStoragePath: supervisorStoragePath)

    // drain the funding contract so the transaction reverts
    let balance = getBalance(address: protocolAccount.address, vaultPublicPath: /public/flowTokenBalance)!
    sendFlow(from: protocolAccount, to: userAccount, amount: balance)

    Test.moveTime(by: 100.0)
    Test.commitBlock()

    // it still executed once but should have no transaction scheduled
    evts = Test.eventsOfType(Type<FlowALPRebalancerv1.Rebalanced>())
    Test.assertEqual(2, evts.length)

    Test.moveTime(by: 1000.0)
    Test.commitBlock()

    // now we fix the missing funds and call fix reschedule
    mintFlow(to: protocolAccount, amount: 1000.0)
    Test.moveTime(by: 60.0* 100.0)
    Test.commitBlock()

    // now supervisor will fix the rebalancer
    evts = Test.eventsOfType(Type<FlowALPSupervisorv1.Executed>())
    Test.assert(evts.length >= 2, message: "Supervisor should have executed at least 2 times")

    evts = Test.eventsOfType(Type<FlowALPRebalancerv1.FixedReschedule>())
    Test.assertEqual(2, evts.length)

    Test.moveTime(by: 10.0)
    Test.commitBlock()

    // now rebalancer could run the transaction again
    evts = Test.eventsOfType(Type<FlowALPRebalancerv1.Rebalanced>())
    Test.assertEqual(3, evts.length)
}