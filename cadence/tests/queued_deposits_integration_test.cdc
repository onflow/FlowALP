import Test
import BlockchainHelpers

import "FlowToken"
import "MOET"
import "test_helpers.cdc"

access(all) var snapshot: UInt64 = 0

access(all)
fun safeReset() {
    let cur = getCurrentBlockHeight()
    if cur > snapshot {
        Test.reset(to: snapshot)
    }
}

access(all)
fun setup() {
    deployContracts()
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    snapshot = getCurrentBlockHeight()
}

access(all)
fun test_getQueuedDeposits_reportsQueuedBalance() {
    safeReset()

    // Give FLOW a hard 100-token per-deposit limit so overflow is guaranteed to queue.
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 100.0,
        depositCapacityCap: 100.0
    )
    setDepositLimitFraction(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        fraction: 1.0
    )

    // Open with 50 FLOW, then deposit 150 more.
    // With a 100-token limit, the second call accepts 50 and queues 100.
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 10_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    createPosition(
        admin: PROTOCOL_ACCOUNT,
        signer: user,
        amount: 50.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )
    depositToPosition(
        signer: user,
        positionID: 0,
        amount: 150.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )

    let queuedDeposits = getQueuedDeposits(pid: 0, beFailed: false)
    let flowType = CompositeType(FLOW_TOKEN_IDENTIFIER)!

    // The getter should expose exactly one queued entry with the 100 FLOW remainder.
    Test.assertEqual(UInt64(1), UInt64(queuedDeposits.length))
    equalWithinVariance(queuedDeposits[flowType]!, 100.0)
}

access(all)
fun test_getQueuedDeposits_tracksPartialAndFullDrain() {
    safeReset()

    // Keep the same capacity, but lower the per-deposit fraction so async drains happen in chunks.
    // After the initial 50 FLOW deposit, the next limit is 25 FLOW, so depositing 150 queues all 150.
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 100.0,
        depositCapacityCap: 100.0
    )
    setDepositLimitFraction(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        fraction: 0.5
    )

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 10_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    createPosition(
        admin: PROTOCOL_ACCOUNT,
        signer: user,
        amount: 50.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )
    depositToPosition(
        signer: user,
        positionID: 0,
        amount: 150.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )

    let flowType = CompositeType(FLOW_TOKEN_IDENTIFIER)!

    var queuedDeposits = getQueuedDeposits(pid: 0, beFailed: false)
    equalWithinVariance(queuedDeposits[flowType]!, 150.0)

    // Regenerate capacity, then drain one chunk.
    // Capacity resets to 200 after one hour, so the next async limit is 100 and 50 should remain queued.
    Test.moveTime(by: 3601.0)
    let firstAsyncRes = _executeTransaction(
        "./transactions/flow-alp/pool-management/async_update_position.cdc",
        [UInt64(0)],
        PROTOCOL_ACCOUNT
    )
    Test.expect(firstAsyncRes, Test.beSucceeded())

    queuedDeposits = getQueuedDeposits(pid: 0, beFailed: false)
    equalWithinVariance(queuedDeposits[flowType]!, 50.0)

    // Regenerate again and drain the last chunk; the queued-deposit map should become empty.
    Test.moveTime(by: 3601.0)
    let secondAsyncRes = _executeTransaction(
        "./transactions/flow-alp/pool-management/async_update_position.cdc",
        [UInt64(0)],
        PROTOCOL_ACCOUNT
    )
    Test.expect(secondAsyncRes, Test.beSucceeded())

    queuedDeposits = getQueuedDeposits(pid: 0, beFailed: false)
    Test.assertEqual(UInt64(0), UInt64(queuedDeposits.length))
}
