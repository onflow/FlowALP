import Test
import BlockchainHelpers

import "MOET"
import "test_helpers.cdc"

/*
    Platform integration tests covering the path used by platforms using FlowALPv1 to create
    and manage new positions. These tests currently only cover the happy path, ensuring that
    transactions creating & updating positions succeed.
 */

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()

    snapshot = getCurrentBlockHeight()
}

access(all)
fun testDeploymentSucceeds() {
    log("Success: contracts deployed")
}

access(all)
fun testCreatePoolSucceeds() {
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)

    let existsRes = _executeScript("../scripts/flow-alp/pool_exists.cdc", [PROTOCOL_ACCOUNT.address])
    Test.expect(existsRes, Test.beSucceeded())

    let exists = existsRes.returnValue as! Bool
    Test.assert(exists)
}

access(all)
fun testCreateUserPositionSucceeds() {
    Test.reset(to: snapshot)

    // mock setup
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)

    // create pool & add FLOW as supported token in globalLedger
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
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

    // Grant beta access to user so they can create positions
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // ensure user does not have a MOET balance
    var moetBalance = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    Test.assertEqual(0.0, moetBalance)

    // ensure there is not yet a position open - fails as there are no open positions yet
    getAvailableBalance(pid: 0, vaultIdentifier: MOET_TOKEN_IDENTIFIER, pullFromTopUpSource: false, beFailed: true)
    
    // open the position & push to drawDownSink - forces MOET to downstream test sink which is user's MOET Vault
    let res = executeTransaction("../transactions/flow-alp/position/create_position.cdc",
            [collateralAmount, FLOW_VAULT_STORAGE_PATH, true], // amount, vaultStoragePath, pushToDrawDownSink
            user
        )
    Test.expect(res, Test.beSucceeded())

    // ensure the position is now open
    let pidZeroBalance = getAvailableBalance(pid: 0, vaultIdentifier: MOET_TOKEN_IDENTIFIER, pullFromTopUpSource: false, beFailed: false)
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
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: initialFlowPrice)

    // create pool & add FLOW as supported token in globalLedger
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
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

    // Grant beta access to user so they can create positions
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // open the position & push to drawDownSink - forces MOET to downstream test sink which is user's MOET Vault
    let res = executeTransaction("../transactions/flow-alp/position/create_position.cdc",
            [collateralAmount, FLOW_VAULT_STORAGE_PATH, true], // amount, vaultStoragePath, pushToDrawDownSink
            user
        )
    Test.expect(res, Test.beSucceeded())

    // check how much MOET the user has after borrowing
    let moetBalanceBeforeRebalance = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    let availableBeforePriceChange = getAvailableBalance(pid: 0, vaultIdentifier: MOET_TOKEN_IDENTIFIER, pullFromTopUpSource: false, beFailed: false)
    let healthBeforePriceChange = getPositionHealth(pid: 0, beFailed: false)

    // decrease the price of the collateral
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: initialFlowPrice * (1.0 - priceChange))
    let availableAfterPriceChange = getAvailableBalance(pid: 0, vaultIdentifier: MOET_TOKEN_IDENTIFIER, pullFromTopUpSource: true, beFailed: false)
    let healthAfterPriceChange = getPositionHealth(pid: 0, beFailed: false)

    // rebalance should pull from the topUpSource, decreasing the MOET in the user's Vault since we use a VaultSource
    // as a topUpSource when opening the Position
    rebalancePosition(signer: PROTOCOL_ACCOUNT, pid: 0, force: true, beFailed: false)

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
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: initialFlowPrice)

    // create pool & add FLOW as supported token in globalLedger
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
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

    // Grant beta access to user so they can create positions
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // open the position & push to drawDownSink - forces MOET to downstream test sink which is user's MOET Vault
    let res = executeTransaction("../transactions/flow-alp/position/create_position.cdc",
            [collateralAmount, FLOW_VAULT_STORAGE_PATH, true], // amount, vaultStoragePath, pushToDrawDownSink
            user
        )
    Test.expect(res, Test.beSucceeded())

    // check how much MOET the user has after borrowing
    let moetBalanceBeforeRebalance = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    let availableBeforePriceChange = getAvailableBalance(pid: 0, vaultIdentifier: MOET_TOKEN_IDENTIFIER, pullFromTopUpSource: false, beFailed: false)
    let healthBeforePriceChange = getPositionHealth(pid: 0, beFailed: false)

    // decrease the price of the collateral
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: initialFlowPrice * (priceChange))
    let availableAfterPriceChange = getAvailableBalance(pid: 0, vaultIdentifier: MOET_TOKEN_IDENTIFIER, pullFromTopUpSource: true, beFailed: false)
    let healthAfterPriceChange = getPositionHealth(pid: 0, beFailed: false)

    // rebalance should pull from the topUpSource, decreasing the MOET in the user's Vault since we use a VaultSource
    // as a topUpSource when opening the Position
    rebalancePosition(signer: PROTOCOL_ACCOUNT, pid: 0, force: true, beFailed: false)

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
