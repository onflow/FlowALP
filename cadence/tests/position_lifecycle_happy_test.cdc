import Test
import BlockchainHelpers

import "MOET"
import "TidalProtocol"
import "test_helpers.cdc"
import "MockTidalProtocolConsumer"

// -----------------------------------------------------------------------------
// Position Lifecycle Happy Path Test
// -----------------------------------------------------------------------------

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) var snapshot: UInt64 = 0

access(all) let flowTokenIdentifier = "A.0000000000000003.FlowToken.Vault"
access(all) var yieldTokenIdentifier = "A.0000000000000007.YieldToken.Vault"
access(all) let flowVaultStoragePath = /storage/flowTokenVault
access(all) let wrapperStoragePath = /storage/tidalProtocolPositionWrapper

access(all)
fun setup() {
    deployContracts()

    snapshot = getCurrentBlockHeight()
}

// -----------------------------------------------------------------------------
access(all)
fun testPositionLifecycleHappyPath() {
    // Test.reset(to: snapshot)

    // price setup
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)

    // create pool & enable token
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // user prep
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 1_000.0)

    let balanceBefore = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    Test.assertEqual(0.0, balanceBefore)

    // open wrapped position (pushToDrawDownSink)
    let openRes = executeTransaction(
        "./transactions/mock-tidal-protocol-consumer/create_wrapped_position.cdc",
        [1_000.0, flowVaultStoragePath, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // confirm position open and user borrowed MOET
    let balanceAfterBorrow = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    Test.assert(balanceAfterBorrow > 0.0)

    // Check Flow balance before repayment
    let flowBalanceBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    log("Flow balance BEFORE repay: ".concat(flowBalanceBefore.toString()))

    /* --- NEW: repay MOET and close position --- */
    let repayRes = executeTransaction(
        "../transactions/tidal-protocol/pool-management/repay_and_close_position.cdc",
        [wrapperStoragePath],
        user
    )
    Test.expect(repayRes, Test.beSucceeded())

    // After repayment, user MOET balance should be 0
    let balanceAfterRepay = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    Test.assertEqual(0.0, balanceAfterRepay)

    let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    log("Flow balance after repay: ".concat(flowBalanceAfter.toString()).concat(" - Collateral successfully returned!"))
    Test.assert(flowBalanceAfter >= 999.99)  // allow tiny rounding diff
} 