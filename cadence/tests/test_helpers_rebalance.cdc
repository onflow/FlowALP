import Test
import "FlowCreditMarketRebalancerV1"

access(self)
fun _executeTransaction(_ path: String, _ args: [AnyStruct], _ signer: Test.TestAccount): Test.TransactionResult {
    let txn = Test.Transaction(
        code: Test.readFile(path),
        authorizers: [signer.address],
        signers: [signer],
        arguments: args
    )
    return Test.executeTransaction(txn)
}

access(all)
fun createPaidRebalancer(
    signer: Test.TestAccount
) {
    let txRes = _executeTransaction(
        "./transactions/rebalancer/create_paid_rebalancer.cdc",
        [],
        signer
    )
    Test.expect(txRes, Test.beSucceeded())
}

access(all)
fun addPaidRebalancerToWrappedPosition(
    signer: Test.TestAccount, 
) {
    let addRes = _executeTransaction(
        "./transactions/rebalancer/add_paid_rebalancer_to_wrapped_position.cdc",
        [],
        signer
    )
    Test.expect(addRes, Test.beSucceeded())
}

access(all)
fun fixPaidReschedule(
    signer: Test.TestAccount,
    uuid: UInt64?
) {
    let setRes = _executeTransaction(
        "./transactions/rebalancer/fix_paid_reschedule.cdc",
        [uuid],
        signer
    )
    Test.expect(setRes, Test.beSucceeded())
}

access(all)
fun changePaidInterval(
    signer: Test.TestAccount,
    uuid: UInt64,
    interval: UInt64,
    expectFailure: Bool
) {
    let setRes = _executeTransaction(
        "./transactions/rebalancer/change_paid_interval.cdc",
        [uuid, interval],
        signer
    )
    Test.expect(setRes, expectFailure ? Test.beFailed() : Test.beSucceeded())
}

access(all)
fun deletePaidRebalancer(
    signer: Test.TestAccount,
) {
    let setRes = _executeTransaction(
        "./transactions/rebalancer/delete_paid_rebalancer.cdc",
        [],
        signer
    )
    Test.expect(setRes, Test.beSucceeded())
}

access(all)
fun createSupervisor(
    signer: Test.TestAccount,
    cronExpression: String,
    cronHandlerStoragePath: StoragePath,
    keeperExecutionEffort: UInt64,
    executorExecutionEffort: UInt64
) {
    let setRes = _executeTransaction(
        "./transactions/rebalancer/create_supervisor.cdc",
        [cronExpression, cronHandlerStoragePath, keeperExecutionEffort, executorExecutionEffort],
        signer
    )
    Test.expect(setRes, Test.beSucceeded())
}

access(all)
fun addPaidRebalancerToSupervisor(
    signer: Test.TestAccount,
    uuid: UInt64
) {
    let setRes = _executeTransaction(
        "./transactions/rebalancer/add_rebalancer_to_supervisor.cdc",
        [uuid],
        signer
    )
    Test.expect(setRes, Test.beSucceeded())
}