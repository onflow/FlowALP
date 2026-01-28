import Test
import BlockchainHelpers

import "MOET"
import "test_helpers.cdc"

access(all) var snapshot: UInt64 = 0


access(all)
fun setup() {
    deployContracts()

    let betaTxResult = grantBeta(PROTOCOL_ACCOUNT, CONSUMER_ACCOUNT)

    snapshot = getCurrentBlockHeight()
}

access(all)
fun testZeroDebtFullWithdrawalAvailable() {
    // 1. price setup
    let initialPrice = 1.0
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: initialPrice)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: MOET_TOKEN_IDENTIFIER, price: initialPrice)

    // 2. pool + token support
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // 3. user setup
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 1_000.0)

    // 4. open position WITHOUT auto-borrow (pushToDrawDownSink = false)
    let openRes = executeTransaction(
        "./transactions/mock-flow-credit-market-consumer/create_wrapped_position.cdc",
        [1_000.0, FLOW_VAULT_STORAGE_PATH, false],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // Position id is 0 (first position)
    let pid: UInt64 = 0

    // 5. Ensure no debt: health should be exactly 1.0
    let health = getPositionHealth(pid: pid, beFailed: false)
    Test.assertEqual(CEILING_HEALTH, health)

    // 6. available balance should equal original collateral (1000)
    let available = getAvailableBalance(pid: pid, vaultIdentifier: FLOW_TOKEN_IDENTIFIER, pullFromTopUpSource: true, beFailed: false)
    Test.assertEqual(1_000.0, available)
} 
