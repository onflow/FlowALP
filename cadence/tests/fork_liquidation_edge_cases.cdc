#test_fork(network: "mainnet-fork", height: 142528994)

import Test
import BlockchainHelpers

import "FlowToken"
import "FungibleToken"
import "MOET"
import "FlowALPEvents"

import "test_helpers.cdc"

access(all) let MAINNET_PROTOCOL_ACCOUNT = Test.getAccount(MAINNET_PROTOCOL_ACCOUNT_ADDRESS)
access(all) let MAINNET_USDF_HOLDER = Test.getAccount(MAINNET_USDF_HOLDER_ADDRESS)
access(all) let MAINNET_WETH_HOLDER = Test.getAccount(MAINNET_WETH_HOLDER_ADDRESS)
access(all) let MAINNET_WBTC_HOLDER = Test.getAccount(MAINNET_WBTC_HOLDER_ADDRESS)
access(all) let MAINNET_FLOW_HOLDER = Test.getAccount(MAINNET_FLOW_HOLDER_ADDRESS)
access(all) let MAINNET_USDC_HOLDER = Test.getAccount(MAINNET_USDC_HOLDER_ADDRESS)

access(all) var snapshot: UInt64 = 0

access(all)
fun safeReset() {
    let cur = getCurrentBlockHeight()
    if cur > snapshot {
        Test.reset(to: snapshot)
    }
}

access(all) fun setup() {
    deployContracts()

    createAndStorePool(signer: MAINNET_PROTOCOL_ACCOUNT, defaultTokenIdentifier: MAINNET_MOET_TOKEN_ID, beFailed: false)

    // Setup pool with plausible mainnet token prices
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_FLOW_TOKEN_ID, price: 1.0)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_USDC_TOKEN_ID, price: 1.0)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_USDF_TOKEN_ID, price: 1.0)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_WETH_TOKEN_ID, price: 3500.0)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_WBTC_TOKEN_ID, price: 50000.0)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_MOET_TOKEN_ID, price: 1.0)

    // Add multiple token types as supported collateral (FLOW, USDC, USDF, WETH, WBTC)
    addSupportedTokenZeroRateCurve(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_FLOW_TOKEN_ID,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    addSupportedTokenZeroRateCurve(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_USDC_TOKEN_ID,
        collateralFactor: 0.85,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    addSupportedTokenZeroRateCurve(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_USDF_TOKEN_ID,
        collateralFactor: 0.85,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    addSupportedTokenZeroRateCurve(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_WETH_TOKEN_ID,
        collateralFactor: 0.75,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // Set minimum deposit for WETH to 0.01 (since holder only has 0.07032)
    setMinimumTokenBalancePerPosition(signer: MAINNET_PROTOCOL_ACCOUNT, tokenTypeIdentifier: MAINNET_WETH_TOKEN_ID, minimum: 0.01)

    addSupportedTokenZeroRateCurve(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_WBTC_TOKEN_ID,
        collateralFactor: 0.75,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )
    // Set minimum deposit for WBTC to 0.00001 (since holder only has 0.0005)
    setMinimumTokenBalancePerPosition(signer: MAINNET_PROTOCOL_ACCOUNT, tokenTypeIdentifier: MAINNET_WBTC_TOKEN_ID, minimum: 0.00001)

    snapshot = getCurrentBlockHeight()
}

// =============================================================================
// Partial Liquidation Sequences — multi-collateral, single crash
//
// 1. User creates 5 positions with different collateral types (FLOW, USDF,
//    USDC, WETH, WBTC), each with MOET debt and health ≈ 1.1.
// 2. FLOW price crash: position 1 health drops to 0.95 (slightly unhealthy).
//    Positions 2–5 remain healthy since their collateral is unaffected.
// 3. Liquidator 1 partially liquidates position 1 in 3 gradual calls
//    (seize 10 / repay 20 each): health 0.95 → 0.9673 → 0.9857 → 1.0052 ≤ 1.05.
//    Fourth attempt by liquidator 1 — fails because the position is now healthy.
// 4. Liquidator 2 attempts to liquidate — fails because the position is now healthy.
// =============================================================================
access(all)
fun testPartialLiquidationSequences() {
    safeReset()

    // --- MOET liquidity provider ---
    let moetLp = Test.createAccount()
    setupMoetVault(moetLp, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: moetLp.address, amount: 50000.0, beFailed: false)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: moetLp, amount: 50000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    // 5 positions with distinct collateral types:
    //
    //  pid | Collateral | Amount       | Borrow   | Crash price  | Health after | Action
    //  ----|------------|--------------|----------|--------------|--------------|--------
    //   1  | FLOW       | 1000 FLOW    | 720 MOET | $0.855 (-14%)| 0.950        | PARTIAL liq x3 (seize 10/repay 20 each → HF 1.0052)
    //   2  | USDF       | 200 USDF     | 154 MOET | unchanged    | 1.104        | NOT liquidated
    //   3  | USDC       | 50 USDC      |  38 MOET | unchanged    | 1.118        | NOT liquidated
    //   4  | WETH       | 0.01 WETH    |  23 MOET | unchanged    | 1.141        | NOT liquidated
    //   5  | WBTC       | 0.0002 WBTC  |   6 MOET | unchanged    | 1.250        | NOT liquidated
    //
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)
    transferTokensWithSetup(tokenIdentifier: MAINNET_USDF_TOKEN_ID, from: MAINNET_USDF_HOLDER, to: user, amount: 200.0)
    transferTokensWithSetup(tokenIdentifier: MAINNET_USDC_TOKEN_ID, from: MAINNET_USDC_HOLDER, to: user, amount: 50.0)
    transferTokensWithSetup(tokenIdentifier: MAINNET_WETH_TOKEN_ID, from: MAINNET_WETH_HOLDER, to: user, amount: 0.01)
    transferTokensWithSetup(tokenIdentifier: MAINNET_WBTC_TOKEN_ID, from: MAINNET_WBTC_HOLDER, to: user, amount: 0.0002)

    // Position 1: FLOW collateral — targeted for liquidation
    // 1000 FLOW @ $1.0, collateralFactor = 0.8 → effectiveCollateral = $800 → borrow 720 MOET
    // health = $800 / $720 ≈ 1.1111
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: 1000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
    let pid1 = getLastPositionId()
    borrowFromPosition(signer: user, positionId: pid1, tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MOET.VaultStoragePath, amount: 720.0, beFailed: false)

    // Position 2: USDF collateral
    // 200 USDF @ $1.0, collateralFactor = 0.85 → effectiveCollateral = $170 → borrow 154 MOET
    // health = $170 / $154 ≈ 1.1038
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: 200.0, vaultStoragePath: MAINNET_USDF_STORAGE_PATH, pushToDrawDownSink: false)
    let pid2 = getLastPositionId()
    borrowFromPosition(signer: user, positionId: pid2, tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MOET.VaultStoragePath, amount: 154.0, beFailed: false)

    // Position 3: USDC collateral
    // 50 USDC @ $1.0, collateralFactor = 0.85 → effectiveCollateral = $42.5 → borrow 38 MOET
    // health = $42.5 / $38 ≈ 1.1184
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: 50.0, vaultStoragePath: MAINNET_USDC_STORAGE_PATH, pushToDrawDownSink: false)
    let pid3 = getLastPositionId()
    borrowFromPosition(signer: user, positionId: pid3, tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MOET.VaultStoragePath, amount: 38.0, beFailed: false)

    // Position 4: WETH collateral (minimum deposit = 0.01)
    // 0.01 WETH @ $3500, collateralFactor = 0.75 → effectiveCollateral = $26.25 → borrow 23 MOET
    // health = $26.25 / $23 ≈ 1.1413
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: 0.01, vaultStoragePath: MAINNET_WETH_STORAGE_PATH, pushToDrawDownSink: false)
    let pid4 = getLastPositionId()
    borrowFromPosition(signer: user, positionId: pid4, tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MOET.VaultStoragePath, amount: 23.0, beFailed: false)

    // Position 5: WBTC collateral (minimum deposit = 0.00001)
    // 0.0002 WBTC @ $50000, collateralFactor = 0.75 → effectiveCollateral = $7.5 → borrow 6 MOET
    // health = $7.5 / $6 = 1.25
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: 0.0002, vaultStoragePath: MAINNET_WBTC_STORAGE_PATH, pushToDrawDownSink: false)
    let pid5 = getLastPositionId()
    borrowFromPosition(signer: user, positionId: pid5, tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MOET.VaultStoragePath, amount: 6.0, beFailed: false)

    // All 5 positions are initially healthy
    Test.assert(getPositionHealth(pid: pid1, beFailed: false) > 1.0, message: "Position 1 (FLOW) should be healthy initially")
    Test.assert(getPositionHealth(pid: pid2, beFailed: false) > 1.0, message: "Position 2 (USDF) should be healthy initially")
    Test.assert(getPositionHealth(pid: pid3, beFailed: false) > 1.0, message: "Position 3 (USDC) should be healthy initially")
    Test.assert(getPositionHealth(pid: pid4, beFailed: false) > 1.0, message: "Position 4 (WETH) should be healthy initially")
    Test.assert(getPositionHealth(pid: pid5, beFailed: false) > 1.0, message: "Position 5 (WBTC) should be healthy initially")

    // --- FLOW price crash: $1.0 → $0.855 ---
    // Position 1: effectiveCollateral = 1000 * 0.855 * 0.8 = $684
    // health = $684 / $720 = 0.95 (unhealthy)
    // Positions 2-5: collateral unaffected, remain healthy
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_FLOW_TOKEN_ID, price: 0.855)
    setMockDexPriceForPair(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        inVaultIdentifier: MAINNET_FLOW_TOKEN_ID,
        outVaultIdentifier: MAINNET_MOET_TOKEN_ID,
        vaultSourceStoragePath: MOET.VaultStoragePath,
        priceRatio: 0.855
    )

    let expectedHealthAfterCrash: UFix128 = 0.95
    Test.assertEqual(expectedHealthAfterCrash, getPositionHealth(pid: pid1, beFailed: false))
    Test.assert(getPositionHealth(pid: pid2, beFailed: false) > 1.0, message: "Position 2 should remain healthy after FLOW crash")
    Test.assert(getPositionHealth(pid: pid3, beFailed: false) > 1.0, message: "Position 3 should remain healthy after FLOW crash")
    Test.assert(getPositionHealth(pid: pid4, beFailed: false) > 1.0, message: "Position 4 should remain healthy after FLOW crash")
    Test.assert(getPositionHealth(pid: pid5, beFailed: false) > 1.0, message: "Position 5 should remain healthy after FLOW crash")

    // === Step 3: Liquidator 1 — gradual partial liquidation of position 1 (3 calls) ===
    // Each call: seize 10 FLOW, repay 20 MOET.
    // DEX check: seize(10) < repay(20) / priceRatio(0.855) = 23.39
    let liquidator1 = Test.createAccount()
    setupMoetVault(liquidator1, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: liquidator1.address, amount: 500.0, beFailed: false)

    // Liquidation call 1:
    // State before: 1000 FLOW, 720 MOET, health = 0.95
    // Post effectiveCollateral = 990 * 0.855 * 0.8 = 677.16
    // Post health = 677.16 / 700 = 0.967371428571428571428571 ≤ 1.05
    let liq1Res = manualLiquidation(
        signer: liquidator1,
        pid: pid1,
        debtVaultIdentifier: MAINNET_MOET_TOKEN_ID,
        seizeVaultIdentifier: MAINNET_FLOW_TOKEN_ID,
        seizeAmount: 10.0,
        repayAmount: 20.0,
    )
    Test.expect(liq1Res, Test.beSucceeded())
    let expectedHealthAfterLiq1: UFix128 = 0.967371428571428571428571
    Test.assertEqual(expectedHealthAfterLiq1, getPositionHealth(pid: pid1, beFailed: false))

    // Liquidation call 2:
    // State before: 990 FLOW, 700 MOET, health = 0.9673...
    // Post effectiveCollateral = 980 * 0.855 * 0.8 = 670.32
    // Post health = 670.32 / 680 = 0.985764705882352941176470 ≤ 1.05
    let liq2Res = manualLiquidation(
        signer: liquidator1,
        pid: pid1,
        debtVaultIdentifier: MAINNET_MOET_TOKEN_ID,
        seizeVaultIdentifier: MAINNET_FLOW_TOKEN_ID,
        seizeAmount: 10.0,
        repayAmount: 20.0,
    )
    Test.expect(liq2Res, Test.beSucceeded())
    let expectedHealthAfterLiq2: UFix128 = 0.985764705882352941176470
    Test.assertEqual(expectedHealthAfterLiq2, getPositionHealth(pid: pid1, beFailed: false))

    // Liquidation call 3:
    // State before: 980 FLOW, 680 MOET, health = 0.9857...
    // Post effectiveCollateral = 970 * 0.855 * 0.8 = 663.48
    // Post health = 663.48 / 660 = 1.005272727272727272727272 ≤ 1.05
    let liq3Res = manualLiquidation(
        signer: liquidator1,
        pid: pid1,
        debtVaultIdentifier: MAINNET_MOET_TOKEN_ID,
        seizeVaultIdentifier: MAINNET_FLOW_TOKEN_ID,
        seizeAmount: 10.0,
        repayAmount: 20.0,
    )
    Test.expect(liq3Res, Test.beSucceeded())
    let expectedHealthAfterLiq3: UFix128 = 1.005272727272727272727272
    Test.assertEqual(expectedHealthAfterLiq3, getPositionHealth(pid: pid1, beFailed: false))

    let detailsAfterLiq3 = getPositionDetails(pid: pid1, beFailed: false)
    let flowCreditAfterLiq3 = getCreditBalanceForType(details: detailsAfterLiq3, vaultType: CompositeType(MAINNET_FLOW_TOKEN_ID)!)
    Test.assertEqual(970.0, flowCreditAfterLiq3)  // 1000 - 30 seized
    let moetDebitAfterLiq3 = getDebitBalanceForType(details: detailsAfterLiq3, vaultType: Type<@MOET.Vault>())
    Test.assertEqual(660.0, moetDebitAfterLiq3)   // 720 - 60 repaid

    // Liquidation call 4: fails because health = 1.00527 > 1.0
    let liq4Res = manualLiquidation(
        signer: liquidator1,
        pid: pid1,
        debtVaultIdentifier: MAINNET_MOET_TOKEN_ID,
        seizeVaultIdentifier: MAINNET_FLOW_TOKEN_ID,
        seizeAmount: 10.0,
        repayAmount: 20.0,
    )
    Test.expect(liq4Res, Test.beFailed())

    // === Step 4: Liquidator 2 — should fail (position is now healthy) ===
    let liquidator2 = Test.createAccount()
    setupMoetVault(liquidator2, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: liquidator2.address, amount: 500.0, beFailed: false)

    let liq5Res = manualLiquidation(
        signer: liquidator2,
        pid: pid1,
        debtVaultIdentifier: MAINNET_MOET_TOKEN_ID,
        seizeVaultIdentifier: MAINNET_FLOW_TOKEN_ID,
        seizeAmount: 10.0,
        repayAmount: 20.0,
    )
    Test.expect(liq5Res, Test.beFailed())
}

// =============================================================================
// Multi-Collateral Position: Liquidator Chooses USDC
//
// A single position holds three collateral types simultaneously: FLOW, USDC,
// and WETH. Debt is USDF. After a FLOW price crash the position becomes
// unhealthy. The liquidator elects to seize USDC.
//
// Collateral table (initial):
//   Type | Amount | Price  | CF   | Effective
//   -----|--------|--------|------|----------
//   FLOW | 200    | $1.00  | 0.80 | $160.00
//   USDC |  50    | $1.00  | 0.85 | $ 42.50
//   WETH | 0.02   | $3500  | 0.75 | $ 52.50
//                                   --------
//                                   $255.00
//
//   Debt: 230 USDF  →  initial health = 255/230 ≈ 1.1087 (healthy)
//
// After FLOW crash ($1.00 → $0.75) — USDF stays $1.00:
//   FLOW effective: 200 × 0.75 × 0.80 = $120.00
//   Total effective: $120 + $42.50 + $52.50 = $215
//   health = 215/230 ≈ 0.9348 (UNHEALTHY)
//
// Liquidation (seize USDC, repay USDF):
//   seize  = 40 USDC, repay = 55 USDF
//   DEX check (USDC→USDF, priceRatio=1.0): seize(40) < repay(55)/1.0 = 55 (passes)
//   post effective: $120 + (50-40)×0.85 + $52.50 = $181
//   post debt:      230 - 55 = 175 USDF
//   post health:    181/175 ≈ 1.0343 <= 1.05 (within target)
//   FLOW balance:   200 (untouched — only USDC seized)
//   WETH balance:   0.02 (untouched — only USDC seized)
//
// Token budget (mainnet at fork height):
//   USDF holder (0xf18b50870aed46ad): 25000 USDF
//     → 5000 to LP + 300 to liquidator = 5300 total (well within budget)
//   USDC holder (0xec6119051f7adc31): 97 USDC → 50 to user
//   WETH holder (0xf62e3381a164f993): 0.07032 WETH → 0.02 to user
//   FLOW service account: 1921 FLOW → 200 to user
// =============================================================================
access(all)
fun testLiquidateMultiCollateralChooseUSDC() {
    safeReset()

    // USDF liquidity provider
    let lpUser = Test.createAccount()
    transferTokensWithSetup(tokenIdentifier: MAINNET_USDF_TOKEN_ID, from: MAINNET_USDF_HOLDER, to: lpUser, amount: 5000.0)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: lpUser, amount: 5000.0, vaultStoragePath: MAINNET_USDF_STORAGE_PATH, pushToDrawDownSink: false)

    // User: FLOW, USDC, WETH
    let user = Test.createAccount()
    var res = setupGenericVault(user, vaultIdentifier: MAINNET_USDF_TOKEN_ID)
    Test.expect(res, Test.beSucceeded())

    // FLOW service account = 0xe467b9dd11fa00df (1921 FLOW)
    // USDC holder          = 0xec6119051f7adc31  (97 USDC)
    // WETH holder          = 0xf62e3381a164f993  (0.07032 WETH)
    transferFlowTokens(to: user, amount: 200.0)
    transferTokensWithSetup(tokenIdentifier: MAINNET_USDC_TOKEN_ID, from: MAINNET_USDC_HOLDER, to: user, amount: 50.0)
    transferTokensWithSetup(tokenIdentifier: MAINNET_WETH_TOKEN_ID, from: MAINNET_WETH_HOLDER, to: user, amount: 0.02)

    // === Build a single multi-collateral position (3 collateral types, 1 position) ===

    // Position collaterals: FLOW + WETH + USDC
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: 200.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
    let pid = getLastPositionId()
    depositToPosition(signer: user, positionID: pid, amount: 50.0, vaultStoragePath: MAINNET_USDC_STORAGE_PATH, pushToDrawDownSink: false)
    depositToPosition(signer: user, positionID: pid, amount: 0.02, vaultStoragePath: MAINNET_WETH_STORAGE_PATH, pushToDrawDownSink: false)

    // Borrow 230 USDF against combined collateral
    // total effective = 160 + 42.5 + 52.5 = $255  →  health = 255/230 ≈ 1.1087
    borrowFromPosition(
        signer: user, positionId: pid,
        tokenTypeIdentifier: MAINNET_USDF_TOKEN_ID, vaultStoragePath: MAINNET_USDF_STORAGE_PATH,
        amount: 230.0, beFailed: false
    )

    let initialHealth = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(initialHealth > 1.1, message: "Initial health should be approx 1.1087 (all 3 collaterals contributing)")

    let detailsBefore = getPositionDetails(pid: pid, beFailed: false)
    Test.assertEqual(200.0, getCreditBalanceForType(details: detailsBefore, vaultType: CompositeType(MAINNET_FLOW_TOKEN_ID)!))
    Test.assertEqual(50.0,  getCreditBalanceForType(details: detailsBefore, vaultType: CompositeType(MAINNET_USDC_TOKEN_ID)!))
    Test.assertEqual(0.02,  getCreditBalanceForType(details: detailsBefore, vaultType: CompositeType(MAINNET_WETH_TOKEN_ID)!))
    Test.assertEqual(230.0, getDebitBalanceForType(details: detailsBefore, vaultType: CompositeType(MAINNET_USDF_TOKEN_ID)!))

    // === FLOW price crash: $1.00 → $0.75 ===
    // USDF stays $1.00 so the debt value is unchanged
    // FLOW effective falls: 200 × 0.75 × 0.80 = $120
    // Total effective:      $120 + $42.50 + $52.50 = $215
    // health = 215/230 ≈ 0.9348 (UNHEALTHY)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_FLOW_TOKEN_ID, price: 0.75)

    transferTokensWithSetup(tokenIdentifier: MAINNET_USDF_TOKEN_ID, from: MAINNET_USDF_HOLDER, to: MAINNET_PROTOCOL_ACCOUNT, amount: 100.0)

    // Configure DEX for USDC→USDF (price check used by manualLiquidation):
    // priceRatio = USDC_price / USDF_price = 1.0
    setMockDexPriceForPair(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        inVaultIdentifier: MAINNET_USDC_TOKEN_ID,
        outVaultIdentifier: MAINNET_USDF_TOKEN_ID,
        vaultSourceStoragePath: MAINNET_USDF_STORAGE_PATH,
        priceRatio: 1.0
    )

    let crashedHealth = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(crashedHealth > 0.9 && crashedHealth < 1.0, message: "Position must be unhealthy after FLOW crash and in range 0.9 - 1.0 (approx 0.9348)")

    // USDC and WETH collateral are unaffected by the FLOW price crash
    let detailsAfterCrash = getPositionDetails(pid: pid, beFailed: false)
    Test.assertEqual(50.0, getCreditBalanceForType(details: detailsAfterCrash, vaultType: CompositeType(MAINNET_USDC_TOKEN_ID)!))
    Test.assertEqual(0.02, getCreditBalanceForType(details: detailsAfterCrash, vaultType: CompositeType(MAINNET_WETH_TOKEN_ID)!))

    // === Liquidator: selects USDC as the optimal seizure target ===
    //
    // seize 40 USDC, repay 55 USDF:
    //   DEX check: seize(40) < repay(55)/priceRatio(1.0)
    //   post effective: 120 + (50-40)×0.85 + 52.5 = 181
    //   post debt:      230 - 55 = 175 USDF
    //   post health:    181/175 ≈ 1.0343 <= 1.05
    let liquidator = Test.createAccount()
    transferTokensWithSetup(tokenIdentifier: MAINNET_USDF_TOKEN_ID, from: MAINNET_USDF_HOLDER, to: liquidator, amount: 300.0)
    // Empty USDC vault to receive the seized collateral
    res = setupGenericVault(liquidator, vaultIdentifier: MAINNET_USDC_TOKEN_ID)
    Test.expect(res, Test.beSucceeded())

    let liqRes = manualLiquidation(
        signer: liquidator,
        pid: pid,
        debtVaultIdentifier: MAINNET_USDF_TOKEN_ID,
        seizeVaultIdentifier: MAINNET_USDC_TOKEN_ID,
        seizeAmount: 40.0,
        repayAmount: 55.0,
    )
    Test.expect(liqRes, Test.beSucceeded())

    // Post-health: 181/175 ≈ 1.034 — healthy and within target (≤ 1.05)
    let postHealth = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(postHealth > 1.0 && postHealth <= 1.05, message: "Position should be healthy after USDC seizure and not exceed liquidationTargetHF (1.05)")
    Test.assert(postHealth > crashedHealth)

    // Selective seizure: only USDC balance changed; FLOW and WETH are untouched
    let detailsAfterLiq = getPositionDetails(pid: pid, beFailed: false)
    Test.assertEqual(200.0, getCreditBalanceForType(details: detailsAfterLiq, vaultType: CompositeType(MAINNET_FLOW_TOKEN_ID)!))  // untouched
    Test.assertEqual(0.02,  getCreditBalanceForType(details: detailsAfterLiq, vaultType: CompositeType(MAINNET_WETH_TOKEN_ID)!))
    // 50 - 40 = 10
    Test.assertEqual(10.0,  getCreditBalanceForType(details: detailsAfterLiq, vaultType: CompositeType(MAINNET_USDC_TOKEN_ID)!))
    // 230 - 55 = 175
    Test.assertEqual(175.0, getDebitBalanceForType(details: detailsAfterLiq, vaultType: CompositeType(MAINNET_USDF_TOKEN_ID)!))   

    // A second liquidation attempt fails — position is now healthy
    let liqRes2 = manualLiquidation(
        signer: liquidator,
        pid: pid,
        debtVaultIdentifier: MAINNET_USDF_TOKEN_ID,
        seizeVaultIdentifier: MAINNET_USDC_TOKEN_ID,
        seizeAmount: 5.0,
        repayAmount: 10.0,
    )
    Test.expect(liqRes2, Test.beFailed())
}

// =============================================================================
// DEX Liquidity Constraints
//
// Scenario: The DEX vault holds only 50% of the debt tokens needed to repay
// the liquidation. A batch DEX liquidation fails atomically, leaving the
// position unchanged and still unhealthy. After topping up the DEX vault,
// the same liquidation parameters succeed.
//
// Position: 200 FLOW @ $1.00 (CF=0.80), borrow 130 USDF
//   health = 200*1.0*0.80 / 130 = 160/130 ≈ 1.2308
// FLOW crash: $1.00 -> $0.75
//   health = 200*0.75*0.80 / 130 = 120/130 ≈ 0.9231 (unhealthy)
// Liquidation params: seize 55 FLOW, repay 46 USDF
//   DEX priceRatio (FLOW->USDF) = 0.75
//   seize 55 < repay/ratio = 46/0.75 = 61.33 (passes DEX check)
//   post-health = (200-55)*0.75*0.80 / (130-46) = 87/84 ≈ 1.036 (within 1.05 target)
// Scenario 1: DEX vault funded with 23 USDF (50% of 46 needed) -> liquidation reverts
// Scenario 2: top up to 53 USDF (>=46) -> liquidation succeeds
// =============================================================================
// access(all) fun testDexLiquidityConstraints()
//
// TODO: DEX Liquidity Constraints test should be implemented once automated liquidation
// is in place. The relevant scenario is: a DEX vault is underfunded relative to the
// debt repayment required, causing an automated liquidation to fail atomically, after
// which topping up the DEX vault allows the same liquidation to succeed. This can only
// be meaningfully tested when FlowALP itself invokes the DEX as part of its liquidation
// code path, rather than the caller supplying pre-swapped funds via manualLiquidation.

// =============================================================================
// Stability and Insurance Fee Accrual — fees not collected for liquidated funds
//
// Insurance and stability fees are collected periodically, based on the total
// debit balance at the time of collection. In practice, this means that these
// fees are an estimate of the actual debit income (they do not account for
// states between collections). This means that, if a debit balance changes
// substantially between collections, we might over- or under-collect fees.
// This test demonstrates this scenario in the case that a liquidation reduces
// the debit balance prior to a collection.
//
// FlowALPv0 protocol revenue comes from interest accrual:
// a fraction of debit income flows to the stability fund (in the debt
// token) and another fraction to the insurance fund (swapped to MOET via DEX).
//
// Setup:
//   USDF fixed interest rate = 10% annual (overrides default zero-rate curve)
//   USDF stability fee rate  = 10% of interest income -> stability fund (USDF)
//   USDF insurance rate      = 10% of interest income -> insurance fund (MOET)
//   Insurance swapper: USDF -> MOET at 1:1 (both stablecoins at $1.00)
//   LP credit rate = debitRate * (1 - protocolFeeRate) = 0.10 * (1 - 0.20) = 0.08 (8%)
//
// Position: 200 FLOW @ $1.00 (CF=0.80), borrow 130 USDF
//   health before crash = 160/130 ≈ 1.2308
// FLOW crash: $1.00 -> $0.75
//   health after crash  = 120/130 ≈ 0.9231 (unhealthy)
// 1 year passes: effective debt ≈ 130 * e^0.10 ≈ 143.67 USDF, health ≈ 0.835
// Liquidation: seize 60 FLOW, repay 63 USDF
//   post-health = (200-60)*0.75*0.80 / (143.67-63) = 84/80.67 ≈ 1.041 (within 1.05 target)
//   totalDebitBalance after liq = 130 - 63 = 67 USDF (principal only)
//
// Fee collection on 67 USDF principal over 1 year:
//   debit income  = 67 * (e^0.10 - 1) ≈ 7.046 USDF
//   stability fee = 7.046 * 0.10 ≈ 0.705 USDF -> stability fund
//   insurance fee = 7.046 * 0.10 ≈ 0.705 USDF -> swapped 1:1 to MOET
// LP credit income (FixedRate: creditRate applied to full LP deposit, not just debt):
//   creditRate = debitRate * (1 - protocolFeeRate) = 0.10 * 0.80 = 0.08
//   LP credit income = 5000 * (e^0.08 - 1) ≈ 416.435 USDF
// =============================================================================
access(all)
fun testStabilityAndInsuranceFees_notCollectedForLiquidatedFunds() {
    safeReset()

    // Override zero-rate curve: 10% annual fixed interest for USDF
    setInterestCurveFixed(signer: MAINNET_PROTOCOL_ACCOUNT, tokenTypeIdentifier: MAINNET_USDF_TOKEN_ID, yearlyRate: 0.1)
    // Stability fee rate: 10% of interest income goes to the stability fund
    Test.expect(setStabilityFeeRate(signer: MAINNET_PROTOCOL_ACCOUNT, tokenTypeIdentifier: MAINNET_USDF_TOKEN_ID, stabilityFeeRate: 0.1), Test.beSucceeded())

    // Insurance setup: MAINNET_PROTOCOL_ACCOUNT's MOET vault serves as the MockDexSwapper source.
    setupMoetVault(MAINNET_PROTOCOL_ACCOUNT, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: MAINNET_PROTOCOL_ACCOUNT.address, amount: 100.0, beFailed: false)
    // Insurance swapper: USDF -> MOET at 1:1
    // Must configure swapper before setting a non-zero insurance rate.
    // Call the transaction directly (bypassing setInsuranceSwapper helper) because that helper
    // hardcodes MOET_TOKEN_ID = "A.0000000000000007.MOET.Vault" (local test address),
    // whereas in fork mode MOET lives at 0x6b00ff876c299c61 (MAINNET_MOET_TOKEN_ID).
    let swapRes = _executeTransaction(
        "./transactions/flow-alp/egovernance/set_insurance_swapper_mock.cdc",
        [MAINNET_USDF_TOKEN_ID, 1.0, MAINNET_USDF_TOKEN_ID, MAINNET_MOET_TOKEN_ID],
        MAINNET_PROTOCOL_ACCOUNT
    )
    Test.expect(swapRes, Test.beSucceeded())
    // Insurance rate: 10% of interest income; stabilityFeeRate 10%
    let rateRes = setInsuranceRate(signer: MAINNET_PROTOCOL_ACCOUNT, tokenTypeIdentifier: MAINNET_USDF_TOKEN_ID, insuranceRate: 0.1)
    Test.expect(rateRes, Test.beSucceeded())

    let initialInsuranceBalance = getInsuranceFundBalance()
    Test.assertEqual(0.0, initialInsuranceBalance)

    // USDF liquidity provider
    let lpUser = Test.createAccount()
    transferTokensWithSetup(tokenIdentifier: MAINNET_USDF_TOKEN_ID, from: MAINNET_USDF_HOLDER, to: lpUser, amount: 5000.0)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: lpUser, amount: 5000.0, vaultStoragePath: MAINNET_USDF_STORAGE_PATH, pushToDrawDownSink: false)
    let lpPid = getLastPositionId()
    let lpBalanceBefore = getCreditBalanceForType(
        details: getPositionDetails(pid: lpPid, beFailed: false),
        vaultType: CompositeType(MAINNET_USDF_TOKEN_ID)!
    )

    // Borrower: 200 FLOW @ $1.00 (CF=0.80), borrow 130 USDF
    // health = 200*1.0*0.80 / 130 = 160/130 ≈ 1.2308 (healthy)
    let user = Test.createAccount()
    let res = setupGenericVault(user, vaultIdentifier: MAINNET_USDF_TOKEN_ID)
    Test.expect(res, Test.beSucceeded())
    transferFlowTokens(to: user, amount: 200.0)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: 200.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
    let pid = getLastPositionId()
    borrowFromPosition(signer: user, positionId: pid,
        tokenTypeIdentifier: MAINNET_USDF_TOKEN_ID, vaultStoragePath: MAINNET_USDF_STORAGE_PATH,
        amount: 130.0, beFailed: false)

    // Stability fund is nil immediately after setup — no time has passed yet
    Test.assertEqual(nil, getStabilityFundBalance(tokenTypeIdentifier: MAINNET_USDF_TOKEN_ID))

    // Advance 1 year BEFORE liquidation: interest accrues on the full 130 USDF debt
    // effective debt ≈ 130 * e^0.10 ≈ 143.67 USDF, health ≈ 120/143.67 ≈ 0.835
    Test.moveTime(by: ONE_YEAR)
    Test.commitBlock()

    // FLOW crash: $1.00 -> $0.75; health = 120/130 ≈ 0.9231 (unhealthy)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_FLOW_TOKEN_ID, price: 0.75)

    // DEX at oracle price
    transferTokensWithSetup(tokenIdentifier: MAINNET_USDF_TOKEN_ID, from: MAINNET_USDF_HOLDER, to: MAINNET_PROTOCOL_ACCOUNT, amount: 100.0)
    setMockDexPriceForPair(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        inVaultIdentifier: MAINNET_FLOW_TOKEN_ID,
        outVaultIdentifier: MAINNET_USDF_TOKEN_ID,
        vaultSourceStoragePath: MAINNET_USDF_STORAGE_PATH,
        priceRatio: 0.75
    )

    // Liquidator: seize 60 FLOW, repay 63 USDF (adjusted for post-1-year debt ~143.67)
    //   DEX check:  seize(60) < repay(63) / priceRatio(0.75) = 84
    //   post-health = (200-60)*0.75*0.80 / (143.67-63) = 84/80.67 ≈ 1.041 (within 1.05 target)
    //   totalDebitBalance after liq = 130 - 63 = 67 USDF (principal)
    let liquidator = Test.createAccount()
    transferTokensWithSetup(tokenIdentifier: MAINNET_USDF_TOKEN_ID, from: MAINNET_USDF_HOLDER, to: liquidator, amount: 200.0)
    let liqRes = manualLiquidation(
        signer: liquidator,
        pid: pid,
        debtVaultIdentifier: MAINNET_USDF_TOKEN_ID,
        seizeVaultIdentifier: MAINNET_FLOW_TOKEN_ID,
        seizeAmount: 60.0,
        repayAmount: 63.0,
    )
    Test.expect(liqRes, Test.beSucceeded())

    // Collect stability fee
    // debitIncome = totalDebitBalance(67) * (e^0.10 - 1) ≈ 7.046 USDF
    // stabilityFee = 7.046 * 0.10 ≈ 0.705 USDF
    Test.expect(collectStability(signer: MAINNET_PROTOCOL_ACCOUNT, tokenTypeIdentifier: MAINNET_USDF_TOKEN_ID), Test.beSucceeded())

    let stabilityBalance = getStabilityFundBalance(tokenTypeIdentifier: MAINNET_USDF_TOKEN_ID)
    Test.assert(stabilityBalance != nil, message: "Stability fund must be non-nil after collection")
    let expectedStabilityFee = 0.705
    let stabilityTolerance = 0.001
    let stabilityDiff = expectedStabilityFee > stabilityBalance! ? expectedStabilityFee - stabilityBalance! : stabilityBalance! - expectedStabilityFee
    Test.assert(stabilityDiff < stabilityTolerance,
        message: "Stability fee should be ≈ 0.705 USDF (totalDebitBalance 67 × (e^0.10-1) × 0.10), got \(stabilityBalance!)")

    // Collect insurance fee: USDF interest income swapped 1:1 to MOET via MockDexSwapper
    // insuranceFee = 7.046 * 0.10 ≈ 0.705 MOET
    collectInsurance(signer: MAINNET_PROTOCOL_ACCOUNT, tokenTypeIdentifier: MAINNET_USDF_TOKEN_ID, beFailed: false)

    let insuranceBalance = getInsuranceFundBalance()
    let expectedInsuranceFee = 0.705
    let insuranceTolerance = 0.001
    let insuranceDiff = expectedInsuranceFee > insuranceBalance ? expectedInsuranceFee - insuranceBalance : insuranceBalance - expectedInsuranceFee
    Test.assert(insuranceDiff < insuranceTolerance,
        message: "Insurance fee should be ≈ 0.705 MOET (totalDebitBalance 67 × (e^0.10-1) × 0.10), got \(insuranceBalance)")

    // Verify LP actually received the credit income:
    //   protocolFeeRate = stabilityFeeRate + insuranceRate = 0.10 + 0.10 = 0.20
    //   creditRate = debitRate * (1 − protocolFeeRate) = 0.10 * 0.80 = 0.08
    //   In FixedRate mode, creditRate applies to the LP's full credit balance (5000 USDF):
    //   LP credit income = 5000 * (e^0.08 - 1) ≈ 416.435 USDF
    let lpBalanceAfter = getCreditBalanceForType(
        details: getPositionDetails(pid: lpPid, beFailed: false),
        vaultType: CompositeType(MAINNET_USDF_TOKEN_ID)!
    )
    let actualLpIncome = lpBalanceAfter - lpBalanceBefore
    let expectedLpIncome = 416.435
    let lpTolerance = 0.01
    let lpDiff = expectedLpIncome > actualLpIncome ? expectedLpIncome - actualLpIncome : actualLpIncome - expectedLpIncome
    Test.assert(lpDiff < lpTolerance,
        message: "LP income ≈ 416.435 USDF (lpDeposit 5000 × (e^creditRate 0.08 - 1)), got \(actualLpIncome)")
}


