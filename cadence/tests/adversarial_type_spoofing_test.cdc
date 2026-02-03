import Test
import BlockchainHelpers

import "MOET"
import "FlowCreditMarket"
import "DeFiActions"
import "DeFiActionsUtils"
import "MockFlowCreditMarketConsumer"
import "FlowToken"
import "test_helpers.cdc"
import "FungibleToken"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) let liquidityAccount = Test.getAccount(0x0000000000000009)
access(all) var hackerAccount = Test.getAccount(0x0000000000000008)

access(all) let flowTokenIdentifier = "A.0000000000000003.FlowToken.Vault"
access(all) let moetTokenIdentifier = "A.0000000000000007.MOET.Vault"
access(all) let flowVaultStoragePath = /storage/flowTokenVault
access(all) let wrapperStoragePath = /storage/flowCreditMarketPositionWrapper

access(all)
fun setup() {
    deployContracts()

    let betaTxResult1 = grantBeta(protocolAccount, liquidityAccount)
    Test.expect(betaTxResult1, Test.beSucceeded())
    let betaTxResult2 = grantBeta(protocolAccount, hackerAccount)
    Test.expect(betaTxResult2, Test.beSucceeded())

    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: 0.0001)
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: moetTokenIdentifier, price: 1.0)

    // Create the Pool & add FLOW as supported token
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: moetTokenIdentifier, beFailed: false)
    addSupportedTokenZeroRateCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.65,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    mintFlow(to: liquidityAccount, amount: 10000.0)
    mintFlow(to: hackerAccount, amount: 2.0)
    setupMoetVault(hackerAccount, beFailed: false)

    // provide liquidity to the pool we can extract
    createWrappedPosition(signer: liquidityAccount, amount: 10000.0, vaultStoragePath: flowVaultStoragePath, pushToDrawDownSink: false)
}

access(all)
fun testMaliciousSource() {
    let hackerBalanceBefore = getBalance(address: hackerAccount.address, vaultPublicPath: /public/flowTokenReceiver) ?? 0.0
    log("[TEST] Hacker's Flow balance before: \(hackerBalanceBefore)")

    // deposit 1 Flow into the position
    let openRes = executeTransaction(
        "./transactions/mock-flow-credit-market-consumer/create_wrapped_position_malicious_source.cdc",
        [1.0, flowVaultStoragePath, false],
        hackerAccount
    )
    Test.expect(openRes, Test.beSucceeded())

    // withdraw 1337 Flow from the position
    let withdrawRes = executeTransaction(
        "./transactions/flow-credit-market/pool-management/withdraw_from_position.cdc",
        [1 as UInt64, flowTokenIdentifier, 1337.0, true],
        hackerAccount
    )
    Test.expect(withdrawRes, Test.beFailed())

    // check the balance of the hacker's account
    let hackerBalance = getBalance(address: hackerAccount.address, vaultPublicPath: /public/flowTokenReceiver) ?? 0.0
    log("[TEST] Hacker's Flow balance: \(hackerBalance)")
}
