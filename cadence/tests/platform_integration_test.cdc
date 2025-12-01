import Test
import BlockchainHelpers

import "MOET"
import "test_helpers.cdc"

/*
    Platform integration tests covering the path used by platforms using FlowCreditMarket to create
    and manage new positions. These tests currently only cover the happy path, ensuring that
    transactions creating & updating positions succeed.
 */

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) let protocolConsumerAccount = Test.getAccount(0x0000000000000008)

access(all) var snapshot: UInt64 = 0

access(all) let flowTokenIdentifier = "A.0000000000000003.FlowToken.Vault"

access(all) let flowVaultStoragePath = /storage/flowTokenVault

access(all)
fun setup() {
    deployContracts()
    let betaTxResult = grantBeta(protocolAccount, protocolConsumerAccount)

    Test.expect(betaTxResult, Test.beSucceeded())

    snapshot = getCurrentBlockHeight()
}

access(all)
fun testDeploymentSucceeds() {
    log("Success: contracts deployed")
}

access(all)
fun testCreatePoolSucceeds() {
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)

    let existsRes = _executeScript("../scripts/flow-credit-market/pool_exists.cdc", [protocolAccount.address])
    Test.expect(existsRes, Test.beSucceeded())

    let exists = existsRes.returnValue as! Bool
    Test.assert(exists)
}

access(all)
fun testCreateUserPositionSucceeds() {
    Test.reset(to: snapshot)

    // mock setup
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)

    // create pool & add FLOW as supported token in globalLedger
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    let collateralAmount = 1_000.0 // FLOW

    // configure user account
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: collateralAmount)

    // ensure user does not have a MOET balance
    var moetBalance = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    Test.assertEqual(0.0, moetBalance)

    // ensure there is not yet a position open - fails as there are no open positions yet
    getAvailableBalance(pid: 0, vaultIdentifier: defaultTokenIdentifier, pullFromTopUpSource: false, beFailed: true)
    
    // open the position & push to drawDownSink - forces MOET to downstream test sink which is user's MOET Vault
    let res = executeTransaction("./transactions/mock-flow-credit-market-consumer/create_wrapped_position.cdc",
            [collateralAmount, flowVaultStoragePath, true], // amount, vaultStoragePath, pushToDrawDownSink
            user
        )
    Test.expect(res, Test.beSucceeded())

    // ensure the position is now open
    let pidZeroBalance = getAvailableBalance(pid: 0, vaultIdentifier: defaultTokenIdentifier, pullFromTopUpSource: false, beFailed: false)
    Test.assert(pidZeroBalance > 0.0)

    // ensure MOET has flown to the user's MOET Vault via the VaultSink provided when opening the position
    moetBalance = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    Test.assert(moetBalance > 0.0)
}

access(all)
fun testUndercollateralizedPositionRebalanceSucceeds() {
    Test.reset(to: snapshot)

    let initialFlowPrice = 1.0 // initial price of FLOW set in the mock oracle
    let priceChange = 0.2 // the percentage difference in the price of FLOW 
    
    // mock setup
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: initialFlowPrice)

    // create pool & add FLOW as supported token in globalLedger
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    let collateralAmount = 1_000.0 // FLOW used when opening the position

    // configure user account
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: collateralAmount)

    // open the position & push to drawDownSink - forces MOET to downstream test sink which is user's MOET Vault
    let res = executeTransaction("./transactions/mock-flow-credit-market-consumer/create_wrapped_position.cdc",
            [collateralAmount, flowVaultStoragePath, true], // amount, vaultStoragePath, pushToDrawDownSink
            user
        )
    Test.expect(res, Test.beSucceeded())

    // check how much MOET the user has after borrowing
    let moetBalanceBeforeRebalance = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    let availableBeforePriceChange = getAvailableBalance(pid: 0, vaultIdentifier: defaultTokenIdentifier, pullFromTopUpSource: false, beFailed: false)
    let healthBeforePriceChange = getPositionHealth(pid: 0, beFailed: false)

    // decrease the price of the collateral
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: initialFlowPrice * (1.0 - priceChange))
    let availableAfterPriceChange = getAvailableBalance(pid: 0, vaultIdentifier: defaultTokenIdentifier, pullFromTopUpSource: true, beFailed: false)
    let healthAfterPriceChange = getPositionHealth(pid: 0, beFailed: false)

    // rebalance should pull from the topUpSource, decreasing the MOET in the user's Vault since we use a VaultSource
    // as a topUpSource when opening the Position
    rebalancePosition(signer: protocolAccount, pid: 0, force: true, beFailed: false)

    let moetBalanceAfterRebalance = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    let healthAfterRebalance = getPositionHealth(pid: 0, beFailed: false)

    // NOTE - exact amounts are not tested here, this is purely a behavioral test though we may update these tests
    
    // user's MOET vault balance decreases due to withdrawal by pool via topUpSource
    Test.assert(moetBalanceBeforeRebalance > moetBalanceAfterRebalance)
    // the amount available should decrease after the collateral value has decreased
    Test.assert(availableBeforePriceChange < availableAfterPriceChange)
    // the health should decrease after the collateral value has decreased
    Test.assert(healthBeforePriceChange > healthAfterPriceChange)
    // the health should increase after rebalancing from undercollateralized state
    Test.assert(healthAfterPriceChange < healthAfterRebalance)
}

access(all)
fun testOvercollateralizedPositionRebalanceSucceeds() {
    Test.reset(to: snapshot)

    let initialFlowPrice = 1.0 // initial price of FLOW set in the mock oracle
    let priceChange = 1.2 // the percentage difference in the price of FLOW 
    
    // mock setup
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: initialFlowPrice)

    // create pool & add FLOW as supported token in globalLedger
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    let collateralAmount = 1_000.0 // FLOW used when opening the position

    // configure user account
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: collateralAmount)

    // open the position & push to drawDownSink - forces MOET to downstream test sink which is user's MOET Vault
    let res = executeTransaction("./transactions/mock-flow-credit-market-consumer/create_wrapped_position.cdc",
            [collateralAmount, flowVaultStoragePath, true], // amount, vaultStoragePath, pushToDrawDownSink
            user
        )
    Test.expect(res, Test.beSucceeded())

    // check how much MOET the user has after borrowing
    let moetBalanceBeforeRebalance = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    let availableBeforePriceChange = getAvailableBalance(pid: 0, vaultIdentifier: defaultTokenIdentifier, pullFromTopUpSource: false, beFailed: false)
    let healthBeforePriceChange = getPositionHealth(pid: 0, beFailed: false)

    // decrease the price of the collateral
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: initialFlowPrice * (priceChange))
    let availableAfterPriceChange = getAvailableBalance(pid: 0, vaultIdentifier: defaultTokenIdentifier, pullFromTopUpSource: true, beFailed: false)
    let healthAfterPriceChange = getPositionHealth(pid: 0, beFailed: false)

    // rebalance should pull from the topUpSource, decreasing the MOET in the user's Vault since we use a VaultSource
    // as a topUpSource when opening the Position
    rebalancePosition(signer: protocolAccount, pid: 0, force: true, beFailed: false)

    let moetBalanceAfterRebalance = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    let healthAfterRebalance = getPositionHealth(pid: 0, beFailed: false)

    // NOTE - exact amounts are not tested here, this is purely a behavioral test though we may update these tests
    
    // user's MOET vault balance increase due to deposit by pool to drawDownSink
    Test.assert(moetBalanceBeforeRebalance < moetBalanceAfterRebalance)
    // the amount available increase after the collateral value has increased
    Test.assert(availableBeforePriceChange < availableAfterPriceChange)
    // the health should increase after the collateral value has decreased
    Test.assert(healthBeforePriceChange < healthAfterPriceChange)
    // the health should decrease after rebalancing from overcollateralized state
    Test.assert(healthAfterPriceChange > healthAfterRebalance)
}
