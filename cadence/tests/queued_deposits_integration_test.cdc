import Test

import "MOET"
import "test_helpers.cdc"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)

access(all)
fun setup() {
    deployContracts()
}

access(all)
fun test_queued_deposits_script_tracks_async_updates() {
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintMoet(signer: protocolAccount, to: user.address, amount: 1_000.0, beFailed: false)

    grantPoolCapToConsumer()

    let openRes = _executeTransaction(
        "./transactions/mock-flow-credit-market-consumer/create_wrapped_position.cdc",
        [50.0, MOET.VaultStoragePath, false],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    let setFracRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-governance/set_deposit_limit_fraction.cdc",
        [defaultTokenIdentifier, 0.0001],
        protocolAccount
    )
    Test.expect(setFracRes, Test.beSucceeded())

    let depositRes = _executeTransaction(
        "./transactions/mock-flow-credit-market-consumer/deposit_to_wrapped_position.cdc",
        [250.0, MOET.VaultStoragePath, false],
        user
    )
    Test.expect(depositRes, Test.beSucceeded())

    let queuedAfterDeposit = getQueuedDeposits(pid: 0, beFailed: false)
    Test.assert(queuedAfterDeposit.length == 1)
    let queuedAmount = queuedAfterDeposit[Type<@MOET.Vault>()]
        ?? panic("Missing queued deposit entry for MOET")
    Test.assert(ufixEqualWithinVariance(150.0, queuedAmount))

    let asyncRes = _executeTransaction(
        "./transactions/flow-credit-market/pool-management/async_update_position.cdc",
        [UInt64(0)],
        protocolAccount
    )
    Test.expect(asyncRes, Test.beSucceeded())

    let queuedAfterPartial = getQueuedDeposits(pid: 0, beFailed: false)
    Test.assert(queuedAfterPartial.length == 1)
    let queuedPartialAmount = queuedAfterPartial[Type<@MOET.Vault>()]
        ?? panic("Missing queued deposit entry after partial update")
    Test.assert(ufixEqualWithinVariance(50.0, queuedPartialAmount))

    let asyncRes2 = _executeTransaction(
        "./transactions/flow-credit-market/pool-management/async_update_position.cdc",
        [UInt64(0)],
        protocolAccount
    )
    Test.expect(asyncRes2, Test.beSucceeded())

    let queuedAfterFull = getQueuedDeposits(pid: 0, beFailed: false)
    Test.assert(queuedAfterFull.length == 0)
}
