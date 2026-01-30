import Test

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
fun unstuck(
    signer: Test.TestAccount
) {
    let setRes = _executeTransaction(
        "./transactions/rebalancer/unstuck.cdc",
        [],
        signer
    )
    Test.expect(setRes, Test.beSucceeded())
}