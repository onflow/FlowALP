import Test
import BlockchainHelpers

import "MOET"
import "FlowALPv0"
import "FlowALPEvents"
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
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: MOET_TOKEN_IDENTIFIER, price: 1.0)
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )
    snapshot = getCurrentBlockHeight()
}

// -----------------------------------------------------------------------------
// Test 1: Happy path: deposit/withdrawal fail during pause and succeed after unpausing
// -----------------------------------------------------------------------------
access(all)
fun test_pool_pause_deposit_withdrawal() {
    safeReset()

    let initialDepositAmount = 100.0
    // Setup users
    let user1 = Test.createAccount()
    setupMoetVault(user1, beFailed: false)
    let mintRes = mintFlow(to: user1, amount: 1000.0)
    Test.expect(mintRes, Test.beSucceeded())

    let user2 = Test.createAccount()
    setupMoetVault(user2, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: user2.address, amount: 1000.0, beFailed: false)

    // create a position for user1
    createPosition(admin: PROTOCOL_ACCOUNT, signer: user1, amount: initialDepositAmount, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    // Pause the pool
    let pauseRes = setPoolPauseState(signer: PROTOCOL_ACCOUNT, pause: true)
    Test.expect(pauseRes, Test.beSucceeded())
    let pauseEvents = Test.eventsOfType(Type<FlowALPEvents.PoolPaused>())
    Test.expect(pauseEvents.length, Test.equal(1))
    // ---------------------------------------------------------

    // Can't deposit to an existing position
    let depositRes = _executeTransaction(
        "./transactions/position-manager/deposit_to_position.cdc",
        [0, 200.0, FLOW_VAULT_STORAGE_PATH, false],
        user1
    )
    Test.expect(depositRes, Test.beFailed())

    // Can't withdraw from existing position
    let withdrawRes = _executeTransaction(
        "./transactions/position-manager/withdraw_from_position.cdc",
        [0, FLOW_TOKEN_IDENTIFIER, initialDepositAmount/2.0, false],
        user1
    )
    Test.expect(withdrawRes, Test.beFailed())

    // Can't create a new position for user2
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user2)
    let openRes = _executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [initialDepositAmount, MOET.VaultStoragePath, false],
        user2
    )
    Test.expect(openRes, Test.beFailed())

    // Unpause the pool
    let unpauseRes = setPoolPauseState(signer: PROTOCOL_ACCOUNT, pause: false)
    Test.expect(unpauseRes, Test.beSucceeded())
    let unpauseEvents = Test.eventsOfType(Type<FlowALPEvents.PoolUnpaused>())
    Test.expect(unpauseEvents.length, Test.equal(1))
    // ---------------------------------------------------------

    // Depositing to position should now succeed
    let depositRes2 = _executeTransaction(
        "./transactions/position-manager/deposit_to_position.cdc",
        [0 as UInt64, 200.0, FLOW_VAULT_STORAGE_PATH, false],
        user1
    )
    Test.expect(depositRes2, Test.beSucceeded())

    // Withdrawing from position should still fail during warmup period
    let withdrawRes2 = _executeTransaction(
        "./transactions/position-manager/withdraw_from_position.cdc",
        [0 as UInt64, FLOW_TOKEN_IDENTIFIER, initialDepositAmount/2.0, false],
        user1
    )
    Test.expect(withdrawRes2, Test.beFailed())

    // Creating new position (for user2) should now succeed
    let openRes2 = _executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [initialDepositAmount, MOET.VaultStoragePath, false],
        user2
    )
    Test.expect(openRes2, Test.beSucceeded())

    // Wait for the warmup period to end (the default warmupSec of FlowALPv0.Pool is 300.0)
    Test.moveTime(by: Fix64(300.0))
    // ---------------------------------------------------------

    // Withdrawing from position should now succeed
    let withdrawRes3 = _executeTransaction(
        "./transactions/position-manager/withdraw_from_position.cdc",
        [0 as UInt64, FLOW_TOKEN_IDENTIFIER, initialDepositAmount/2.0, false],
        user1
    )
    Test.expect(withdrawRes3, Test.beSucceeded())


}
