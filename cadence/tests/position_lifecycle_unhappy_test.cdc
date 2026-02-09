import Test
import BlockchainHelpers

import "MOET"
import "FlowCreditMarket"
import "test_helpers.cdc"

// -----------------------------------------------------------------------------
// Position Lifecycle Unhappy Path Test
// -----------------------------------------------------------------------------

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()

    snapshot = getCurrentBlockHeight()
}

// -----------------------------------------------------------------------------
access(all)
fun testPositionLifecycleBelowMinimumDeposit() {
    // price setup
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)

    // create pool & enable token
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    let minimum = 10.0

    setMinimumTokenBalancePerPosition(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER, minimum: minimum)

    // position id to use for tests
    let positionId = 0 as UInt64

    // user prep
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 1_000.0)

    // Grant beta access to user so they can create positions
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    let balanceBefore = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    Test.assertEqual(0.0, balanceBefore)

    // open wrapped position (pushToDrawDownSink)
    let openWithLessThanMinRes = executeTransaction(
        "../transactions/flow-credit-market/position/create_position.cdc",
        [minimum-0.1, FLOW_VAULT_STORAGE_PATH, true],
        user
    )
    Test.expect(openWithLessThanMinRes, Test.beFailed())

    let amountAboveMin = 1.0

    // open wrapped position (pushToDrawDownSink)
    let openRes = executeTransaction(
        "../transactions/flow-credit-market/position/create_position.cdc",
        [minimum+amountAboveMin, FLOW_VAULT_STORAGE_PATH, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // Attempt to withdraw the exact amount above the minimum
    let withdrawResSuccess = _executeTransaction(
        "./transactions/position-manager/withdraw_from_position.cdc",
        [positionId, FLOW_TOKEN_IDENTIFIER, amountAboveMin, true],
        user
    )

    Test.expect(withdrawResSuccess, Test.beSucceeded())

    // Amount should now be exactly the minimum, so withdrawal should fail
    let withdrawResFail = _executeTransaction(
        "./transactions/position-manager/withdraw_from_position.cdc",
        [positionId, FLOW_TOKEN_IDENTIFIER, amountAboveMin, true],
        user
    )

    Test.expect(withdrawResFail, Test.beFailed())
} 
