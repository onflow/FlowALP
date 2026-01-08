import Test
import BlockchainHelpers

import "MOET"
import "test_helpers.cdc"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) let protocolConsumerAccount = Test.getAccount(0x0000000000000008)
access(all) var snapshot: UInt64 = 0

access(all) let flowTokenIdentifier = "A.0000000000000003.FlowToken.Vault"
access(all) let flowVaultStoragePath = /storage/flowTokenVault

access(all)
fun setup() {
    deployContracts()

    let betaTxResult = grantBeta(protocolAccount, protocolConsumerAccount)

    snapshot = getCurrentBlockHeight()
}

access(all)
fun testZeroDebtFullWithdrawalAvailable() {
    // 1. price setup
    let initialPrice = 1.0
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: initialPrice)
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: defaultTokenIdentifier, price: initialPrice)

    // 2. pool + token support
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)
    addSupportedTokenZeroRateCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
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
        [1_000.0, flowVaultStoragePath, false],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // Position id is 0 (first position)
    let pid: UInt64 = 0

    // 5. Ensure no debt: health should be exactly 1.0
    let health = getPositionHealth(pid: pid, beFailed: false)
    Test.assertEqual(ceilingHealth, health)

    // 6. available balance should equal original collateral (1000)
    let available = getAvailableBalance(pid: pid, vaultIdentifier: flowTokenIdentifier, pullFromTopUpSource: true, beFailed: false)
    Test.assertEqual(1_000.0, available)
} 
