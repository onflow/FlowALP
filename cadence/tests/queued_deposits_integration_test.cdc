import Test
import BlockchainHelpers

import "FlowToken"
import "MOET"
import "test_helpers.cdc"

access(all) var snapshot: UInt64 = 0

access(all)
fun safeReset() {
    // Reuse one deployed test environment and rewind to the post-setup block height
    // before each case so both tests run against the same clean pool state.
    let cur = getCurrentBlockHeight()
    if cur > snapshot {
        Test.reset(to: snapshot)
    }
}

access(all)
fun setup() {
    // Deploy contracts once and snapshot the baseline state used by safeReset().
    deployContracts()
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    snapshot = getCurrentBlockHeight()
}

access(all)
fun test_getQueuedDeposits_reportsQueuedBalance() {
    safeReset()

    // Configure FLOW so the pool has 100 total deposit capacity and allows using all
    // currently available capacity in one call. This makes the queueing math simple:
    // after 50 FLOW is accepted during position creation, only 50 more can be accepted
    // immediately and any extra deposit must be queued.
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

    // Create a user with enough FLOW to open a position and then overflow the remaining
    // deposit capacity in a second transaction.
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 10_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // The first 50 FLOW is accepted into the position and leaves 50 capacity remaining.
    createPosition(
        admin: PROTOCOL_ACCOUNT,
        signer: user,
        amount: 50.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )

    // This 150 FLOW deposit therefore splits into:
    // - 50 accepted immediately
    // - 100 stored in the queued-deposits map
    depositToPosition(
        signer: user,
        positionID: 0,
        amount: 150.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )

    // Read the queued balances through the new public script path under test.
    let queuedDeposits = getQueuedDeposits(pid: 0, beFailed: false)
    let flowType = CompositeType(FLOW_TOKEN_IDENTIFIER)!

    // We expect exactly one queued token type, and its balance should be the
    // 100 FLOW remainder that could not be accepted immediately.
    Test.assertEqual(UInt64(1), UInt64(queuedDeposits.length))
    equalWithinVariance(queuedDeposits[flowType]!, 100.0)
}

access(all)
fun test_getQueuedDeposits_tracksPartialAndFullDrain() {
    safeReset()

    // Keep the same 100-capacity token setup, but lower the limit fraction to 0.5.
    // That makes the user's deposit limit cap 50 FLOW total. After the initial 50 FLOW
    // position creation, the position has already used that full allowance, so the next
    // 150 FLOW deposit is queued instead of being accepted immediately.
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

    // Consume the user's full 50 FLOW allowance.
    createPosition(
        admin: PROTOCOL_ACCOUNT,
        signer: user,
        amount: 50.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )

    // Because the position is already at its per-user limit, this entire 150 FLOW
    // deposit remains queued.
    depositToPosition(
        signer: user,
        positionID: 0,
        amount: 150.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: false
    )

    let flowType = CompositeType(FLOW_TOKEN_IDENTIFIER)!

    // The new getter should initially report the full queued amount.
    var queuedDeposits = getQueuedDeposits(pid: 0, beFailed: false)
    equalWithinVariance(queuedDeposits[flowType]!, 150.0)

    // After one hour, deposit capacity regenerates by the configured depositRate.
    // That takes the capacity cap from 100 to 200, so async processing can now accept
    // up to 100 FLOW from the queue and should leave 50 still queued.
    Test.moveTime(by: 3601.0)
    let firstAsyncRes = _executeTransaction(
        "./transactions/flow-alp/eimplementation/async_update_position.cdc",
        [UInt64(0)],
        PROTOCOL_ACCOUNT
    )
    Test.expect(firstAsyncRes, Test.beSucceeded())

    queuedDeposits = getQueuedDeposits(pid: 0, beFailed: false)
    equalWithinVariance(queuedDeposits[flowType]!, 50.0)

    // Move forward another hour and run async processing again. The final 50 FLOW
    // should be deposited, leaving no queued entries behind.
    Test.moveTime(by: 3601.0)
    let secondAsyncRes = _executeTransaction(
        "./transactions/flow-alp/eimplementation/async_update_position.cdc",
        [UInt64(0)],
        PROTOCOL_ACCOUNT
    )
    Test.expect(secondAsyncRes, Test.beSucceeded())

    queuedDeposits = getQueuedDeposits(pid: 0, beFailed: false)
    Test.assertEqual(UInt64(0), UInt64(queuedDeposits.length))
}
