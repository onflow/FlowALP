import Test
import BlockchainHelpers

import "FlowALPv0"
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

    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // DEX swapper for FLOW → MOET (price 1:1, matches oracle)
    setMockDexPriceForPair(
        signer: PROTOCOL_ACCOUNT,
        inVaultIdentifier: FLOW_TOKEN_IDENTIFIER,
        outVaultIdentifier: MOET_TOKEN_IDENTIFIER,
        vaultSourceStoragePath: MOET.VaultStoragePath,
        priceRatio: 1.0
    )

    snapshot = getCurrentBlockHeight()
}

/// ============================================================
/// Malicious topUpSource leads to liquidation
///
/// Simulates a topUpSource that provides no funds, preventing rebalancing
/// after the position becomes undercollateralized. The position
/// remains liquidatable and is successfully liquidated.
/// ============================================================
access(all)
fun testRebalance_MaliciousTopUpSource_EnablesLiquidation() {
    safeReset()

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    let mintRes = mintFlow(to: user, amount: 1_000.0)
    Test.expect(mintRes, Test.beSucceeded())
    createPosition(admin: PROTOCOL_ACCOUNT, signer: user, amount: 1_000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: true)

    // completely empty the topUpSource so that any withdrawal returns 0
    let drain = Test.createAccount()
    setupMoetVault(drain, beFailed: false)
    let userMoet = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    transferFungibleTokens(
        tokenIdentifier: MOET_TOKEN_IDENTIFIER,
        from: user,
        to: drain,
        amount: userMoet  // all amount
    )

    // crash price so health falls below 1.0
    let crashPrice = 0.5
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: crashPrice)
    setMockDexPriceForPair(
        signer: PROTOCOL_ACCOUNT,
        inVaultIdentifier: FLOW_TOKEN_IDENTIFIER,
        outVaultIdentifier: MOET_TOKEN_IDENTIFIER,
        vaultSourceStoragePath: MOET.VaultStoragePath,
        priceRatio: crashPrice
    )

    Test.assert(getPositionHealth(pid: 0, beFailed: false) < 1.0, message: "Position must be liquidatable after price crash")

    // rebalance attempt should fail cause source has 0 MOET
    let rebalanceRes = rebalancePosition(signer: PROTOCOL_ACCOUNT, pid: 0, force: true)
    Test.expect(rebalanceRes, Test.beFailed())
    Test.assertError(rebalanceRes, errorMessage: "topUpSource insufficient to save position from liquidation")

    // position is still liquidatable
    Test.assert(getPositionHealth(pid: 0, beFailed: false) < 1.0,message: "Position should remain liquidatable after failed rebalance",)

    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: liquidator.address, amount: 1_000.0, beFailed: false)

    let repayAmount = 100.0
    let seizeAmount = 150.0

    let collateralPreLiq = getPositionBalance(pid: 0, vaultID: FLOW_TOKEN_IDENTIFIER).balance
    let debtPreLiq       = getPositionBalance(pid: 0, vaultID: MOET_TOKEN_IDENTIFIER).balance
    let liqMoetBefore    = getBalance(address: liquidator.address, vaultPublicPath: MOET.VaultPublicPath)!

    let liqRes = manualLiquidation(
        signer: liquidator,
        pid: 0,
        debtVaultIdentifier: Type<@MOET.Vault>().identifier,
        seizeVaultIdentifier: FLOW_TOKEN_IDENTIFIER,
        seizeAmount: seizeAmount,
        repayAmount: repayAmount
    )
    Test.expect(liqRes, Test.beSucceeded())

    // position lost exactly the liquidated amounts
    let collateralPostLiq = getPositionBalance(pid: 0, vaultID: FLOW_TOKEN_IDENTIFIER).balance
    let debtPostLiq       = getPositionBalance(pid: 0, vaultID: MOET_TOKEN_IDENTIFIER).balance
    Test.assertEqual(collateralPostLiq, collateralPreLiq - seizeAmount)
    Test.assertEqual(debtPostLiq, debtPreLiq - repayAmount)

    // liquidator spent MOET and received FLOW
    let liqMoetAfter = getBalance(address: liquidator.address, vaultPublicPath: MOET.VaultPublicPath)!
    let liqFlowAfter = getBalance(address: liquidator.address, vaultPublicPath: /public/flowTokenBalance)!
    Test.assertEqual(liqMoetBefore - liqMoetAfter, repayAmount)
    Test.assertEqual(liqFlowAfter, seizeAmount)
}

/// ============================================================
/// Rebalance skipped due to DrawDownSink rejection
///
/// Simulates an overcollateralised position where rebalance attempts
/// to push surplus funds to the drawDownSink, but the sink cannot
/// accept cause was removed
/// ============================================================
access(all)
fun testRebalance_DrawDownSinkRejection() {
    safeReset()

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1_000.0)

    createPosition(
        admin: PROTOCOL_ACCOUNT,
        signer: user,
        amount: 1_000.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: true
    )

    let initialDebt = getPositionBalance(pid: 0, vaultID: MOET_TOKEN_IDENTIFIER).balance
    let healthBeforePriceChange = getPositionHealth(pid: 0, beFailed: false)

    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.5)

    // price increase, position even more overcollateralised
    let healthAfterPrice = getPositionHealth(pid: 0, beFailed: false)
    Test.assert(healthAfterPrice >= INT_MAX_HEALTH, message: "Position should be overcollateralized after price increase, health=\(healthAfterPrice.toString())")
    
    let moetInVaultBeforeRebalance = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!

    // remove the drawDownSink, so rebalance cannot push surplus to drawDownSink
    let setSinkRes = setDrawDownSink(signer: user, pid: 0, sink: nil)
    Test.expect(setSinkRes, Test.beSucceeded())

    let rebalanceRes = rebalancePosition(signer: PROTOCOL_ACCOUNT, pid: 0, force: true)
    Test.expect(rebalanceRes, Test.beSucceeded())

    let healthAfterRebalance = getPositionHealth(pid: 0, beFailed: false)
    let moetInVaultAfterRebalance = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!

    // debt and health stay the same
    Test.assertEqual(moetInVaultAfterRebalance, moetInVaultBeforeRebalance)
    let debtAfterRebalance = getPositionBalance(pid: 0, vaultID: MOET_TOKEN_IDENTIFIER).balance
    Test.assertEqual(initialDebt, debtAfterRebalance)
    Test.assert(healthAfterRebalance >= INT_TARGET_HEALTH, message: "Health should remain above targetHealth when sink is at capacity (health=\(healthAfterRebalance.toString()))")
    Test.assertEqual(healthAfterRebalance, healthAfterPrice)
}

/// ============================================================
/// Rebalance exceeds gas limits for large position set
///
/// Simulates many overcollateralised positions requiring rebalance.
/// Since asyncUpdate processes a limited batch per call, attempting
/// to handle too many positions in one transaction exceeds the
/// computation limit and fails.
/// ============================================================
access(all)
fun testRebalance_AsyncUpdate_ProcessesAtMostConfiguredBatchSize() {
    safeReset()

    // open positions so they land in the update queue
    let numPositions = 150
    var pid: UInt64 = 0
    while pid < UInt64(numPositions) {
        let user = Test.createAccount()
        setupMoetVault(user, beFailed: false)
        let mintRes = mintFlow(to: user, amount: 1_000.0)
        Test.expect(mintRes, Test.beSucceeded())
        createPosition(
            admin: PROTOCOL_ACCOUNT,
            signer: user,
            amount: 1_000.0,
            vaultStoragePath: /storage/flowTokenVault,
            pushToDrawDownSink: true
        )
        pid = pid + 1
    }

    // drop price: all positions overcollateralised
    //   effectiveCollateral = 1000 × 1.2 × 0.8 = 960
    //   effectiveDebt       ≈ 615.38
    //   health              ≈ 1.56 > maxHealth (1.5)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.2)

    // try to asyncUpdate for rebalancing positions back toward targetHealth (1.3)
    let asyncUpdateRes = asyncUpdate()
    Test.expect(asyncUpdateRes, Test.beFailed())
    Test.assertError(asyncUpdateRes, errorMessage: "computation exceeds limit")

    // all positions should have not been processed 
    var i: UInt64 = 0
    while i < UInt64(numPositions) {
        let h = getPositionHealth(pid: i, beFailed: false)
        Test.assert(h > INT_MAX_HEALTH, message: "Position \(i.toString()) should be overcollateralised")
        i = i + 1
    }
}

/// ============================================================
/// Shared liquidity source across positions
///
/// Two positions share the same topUpSource. After a price drop, only one can
/// be rebalanced due to limited funds; the first succeeds, the second fails
/// and remains liquidatable.
/// ============================================================
access(all)
fun testRebalance_ConcurrentRebalances() {
    safeReset()

    let user = Test.createAccount()
    let drain = Test.createAccount()

    setupMoetVault(user, beFailed: false)
    setupMoetVault(drain, beFailed: false)

    var mintRes = mintFlow(to: user, amount: 2_000.0)
    Test.expect(mintRes, Test.beSucceeded())

    createPosition(admin: PROTOCOL_ACCOUNT, signer: user, amount: 1_000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: true)
    createPosition(admin: PROTOCOL_ACCOUNT, signer: user, amount: 1_000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: true)

    // minHealth = 1.1: required deposit per position to reach minHealth after 50% price crash:
    //   effectiveCollateral = 1 000 * 0.5 * 0.8 = 400
    //   effectiveDebt       ≈ 615.38
    //
    // Ideal health = 400 / (615.38 - required) = 1.3
    // Required MOET ≈ 307.69 MOET
    //
    // left 310 MOET which is enough for one position, not both
    let moetAmount = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    transferFungibleTokens(tokenIdentifier: MOET_TOKEN_IDENTIFIER, from: user, to: drain, amount: moetAmount - 310.0)

    // drop price so both positions fall below health 1.0
    // effectiveCollateral = 1000 * 0.5 * 0.8 = 400; debt ≈ 615 → health ≈ 0.65
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 0.5)

    Test.assert(getPositionHealth(pid: 0, beFailed: false) < 1.0, message: "Position should be undercollateralised")
    Test.assert(getPositionHealth(pid: 1, beFailed: false) < 1.0, message: "Position should be undercollateralised")
    let userMoetBefore = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!

    // first rebalance (position 0): user has 310 MOET — enough to rescue
    let rebalanceRes0 = rebalancePosition(signer: PROTOCOL_ACCOUNT, pid: 0, force: true)
    Test.expect(rebalanceRes0, Test.beSucceeded())

    let userMoetAfterFirst = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    Test.assert(
        userMoetAfterFirst < userMoetBefore,
        message: "user's MOET should have decreased after first rebalance (before=\(userMoetBefore.toString()), after=\(userMoetAfterFirst.toString()))"
    )

    let health0AfterFirst = getPositionHealth(pid: 0, beFailed: false)
    Test.assert(
        health0AfterFirst >= 1.0,
        message: "Position 0 should be healthy after first rebalance (health=\(health0AfterFirst.toString()))"
    )
    
    // second rebalance (position 1): user has ≈ 2.3 MOET — not enough to rescue
    let rebalance1 = rebalancePosition(signer: PROTOCOL_ACCOUNT, pid: 1, force: true)
    Test.expect(rebalance1, Test.beFailed())
    Test.assertError(rebalance1, errorMessage: "topUpSource insufficient to save position from liquidation")

    // position 1 remains undercollateralised and open for liquidation
    let health1AfterSecond = getPositionHealth(pid: 1, beFailed: false)
    Test.assert(
        health1AfterSecond < 1.0,
        message: "Position 1 should remain undercollateralised after failed second rebalance (health=\(health1AfterSecond.toString()))"
    )
}
