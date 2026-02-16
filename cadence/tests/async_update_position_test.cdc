import Test
import BlockchainHelpers
import "FlowCreditMarket"

import "test_helpers.cdc"

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()

    snapshot = getCurrentBlockHeight()
}

access(all)
fun testUpdatePosition() {
    let initialPrice = 1.0
    let priceIncreaseFactor: UFix64 = 1.2
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: initialPrice)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: MOET_TOKEN_IDENTIFIER, price: initialPrice)

    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000.0,
        depositCapacityCap: 1_000.0
    )

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 1_000.0)

    createPosition(admin: PROTOCOL_ACCOUNT, signer: user, amount: 100.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    // increase price
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: initialPrice * priceIncreaseFactor)

    depositToPosition(signer: user, positionID: 0, amount: 600.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    let updatePositionRes = _executeTransaction(
        "./transactions/flow-credit-market/pool-management/async_update_position.cdc",
        [ 0 as UInt64 ],
        PROTOCOL_ACCOUNT
    )
    Test.expect(updatePositionRes, Test.beSucceeded())
} 
