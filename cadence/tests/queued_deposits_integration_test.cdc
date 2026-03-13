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

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 10_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    let openRes = _executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [50.0, FLOW_VAULT_STORAGE_PATH, false],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    let depositRes = _executeTransaction(
        "./transactions/position/deposit_to_position_by_id.cdc",
        [UInt64(0), 150.0, FLOW_VAULT_STORAGE_PATH, false],
        user
    )
    Test.expect(depositRes, Test.beSucceeded())

    let queuedDeposits = getQueuedDeposits(pid: 0, beFailed: false)
    let flowType = CompositeType(FLOW_TOKEN_IDENTIFIER)!

    Test.assertEqual(UInt64(1), UInt64(queuedDeposits.length))
    equalWithinVariance(queuedDeposits[flowType]!, 100.0)
}

access(all)
fun test_getQueuedDeposits_tracksPartialAndFullDrain() {
    safeReset()

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

    let openRes = _executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [50.0, FLOW_VAULT_STORAGE_PATH, false],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    let depositRes = _executeTransaction(
        "./transactions/position/deposit_to_position_by_id.cdc",
        [UInt64(0), 150.0, FLOW_VAULT_STORAGE_PATH, false],
        user
    )
    Test.expect(depositRes, Test.beSucceeded())

    let flowType = CompositeType(FLOW_TOKEN_IDENTIFIER)!

    var queuedDeposits = getQueuedDeposits(pid: 0, beFailed: false)
    equalWithinVariance(queuedDeposits[flowType]!, 150.0)

    Test.moveTime(by: 3601.0)
    let firstAsyncRes = _executeTransaction(
        "./transactions/flow-alp/pool-management/async_update_position.cdc",
        [UInt64(0)],
        PROTOCOL_ACCOUNT
    )
    Test.expect(firstAsyncRes, Test.beSucceeded())

    queuedDeposits = getQueuedDeposits(pid: 0, beFailed: false)
    equalWithinVariance(queuedDeposits[flowType]!, 50.0)

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
