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

// ─── Protocol constants (set once in setup(), referenced in formula comments) ──

// Initial oracle prices
access(all) let PRICE_FLOW  = 1.0
access(all) let PRICE_USDC  = 1.0
access(all) let PRICE_USDF  = 1.0
access(all) let PRICE_WETH  = 3500.0
access(all) let PRICE_WBTC  = 50000.0
access(all) let PRICE_MOET  = 1.0

// Collateral factors
access(all) let CF_FLOW = 0.80
access(all) let CF_USDC = 0.85
access(all) let CF_USDF = 0.85
access(all) let CF_WETH = 0.75
access(all) let CF_WBTC = 0.75

// Minimum token balance per position
access(all) let MIN_BAL_WETH = 0.01
access(all) let MIN_BAL_WBTC = 0.00001

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

    // Set oracle prices
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_FLOW_TOKEN_ID, price: PRICE_FLOW)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_USDC_TOKEN_ID, price: PRICE_USDC)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_USDF_TOKEN_ID, price: PRICE_USDF)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_WETH_TOKEN_ID, price: PRICE_WETH)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_WBTC_TOKEN_ID, price: PRICE_WBTC)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_MOET_TOKEN_ID, price: PRICE_MOET)

    // Add multiple token types as supported collateral (FLOW, USDC, USDF, WETH, WBTC)
    addSupportedTokenZeroRateCurve(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_FLOW_TOKEN_ID,
        collateralFactor: CF_FLOW,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    addSupportedTokenZeroRateCurve(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_USDC_TOKEN_ID,
        collateralFactor: CF_USDC,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    addSupportedTokenZeroRateCurve(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_USDF_TOKEN_ID,
        collateralFactor: CF_USDF,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    addSupportedTokenZeroRateCurve(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_WETH_TOKEN_ID,
        collateralFactor: CF_WETH,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // Set minimum deposit for WETH to MIN_BAL_WETH (since holder only has 0.07032)
    setMinimumTokenBalancePerPosition(signer: MAINNET_PROTOCOL_ACCOUNT, tokenTypeIdentifier: MAINNET_WETH_TOKEN_ID, minimum: MIN_BAL_WETH)

    addSupportedTokenZeroRateCurve(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_WBTC_TOKEN_ID,
        collateralFactor: CF_WBTC,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )
    // Set minimum deposit for WBTC to MIN_BAL_WBTC (since holder only has 0.0005)
    setMinimumTokenBalancePerPosition(signer: MAINNET_PROTOCOL_ACCOUNT, tokenTypeIdentifier: MAINNET_WBTC_TOKEN_ID, minimum: MIN_BAL_WBTC)

    snapshot = getCurrentBlockHeight()
}

// =============================================================================
// Multiple Positions Per User
//
// Validates that a single user can hold 5 independent positions with distinct
// collateral types, and that operations on one position have no effect on any
// other (isolation guarantee).
//
// Pool liquidity: 800 MOET LP deposit
//
// Positions (all borrow MOET as debt):
//   pos 1:  500 FLOW    @ 1.00 MOET (CF=0.80), borrow 100  → health = 500*1.0*0.80/100     = 4.000
//   pos 2: 1500 USDF    @ 1.00 MOET (CF=0.85), borrow 150  → health = 1500*1.0*0.85/150    = 8.500
//   pos 3:   10 USDC    @ 1.00 MOET (CF=0.85), borrow   5  → health = 10*1.0*0.85/5        = 1.700
//   pos 4: 0.05 WETH    @ 3500 MOET (CF=0.75), borrow  50  → health = 0.05*3500*0.75/50    = 2.625
//   pos 5: 0.0004 WBTC  @ 50000 MOET (CF=0.75), borrow  8  → health = 0.0004*50000*0.75/8  = 1.875
//
// Isolation test: borrow 100 more MOET from pos 2 (USDF)
//   new debt = 150 + 100 = 250  →  health = 1500*1.0*0.85/250 = 5.100  (lower)
//   pos 1, 3, 4, 5: unchanged
// =============================================================================
access(all) fun testMultiplePositionsPerUser() {
    safeReset()

    log("Testing Multiple Positions with Real Mainnet Tokens\n")

    let lpUser = Test.createAccount()
    let user = Test.createAccount()

    // Mint MOET to LP to create liquidity for borrowing
    log("Setting up liquidity provider with MOET\n")
    let liquidityAmount = 800.0
    setupMoetVault(lpUser, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: lpUser.address, amount: liquidityAmount, beFailed: false)

    // LP deposits MOET to create liquidity for borrowing
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: lpUser, amount: liquidityAmount, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    //////////// Position creation ///////////////////
    log("Create 5 Positions with Different Collateral Types\n")

    // Define positions with different collateral types
    // Token holder balances and prices:
    // - flowHolder: 1921 FLOW x 1 = 1921 MOET
    // - usdfHolder: 25000 USDF x 1 = 25000 MOET
    // - usdcHolder: 97 USDC x 1 = 97 MOET
    // - wethHolder: 0.07032 WETH x 3500 = 246.12 MOET
    // - wbtcHolder: 0.0005 WBTC x 50000 = 25 MOET
    //
    // health = col * PRICE * CF / debt
    let flowCol = 500.0;  let flowDebt = 100.0  // health = 500.0  * PRICE_FLOW * CF_FLOW / 100.0  = 4.000
    let usdfCol = 1500.0; let usdfDebt = 150.0  // health = 1500.0 * PRICE_USDF * CF_USDF / 150.0  = 8.500
    let usdcCol = 10.0;   let usdcDebt = 5.0    // health = 10.0   * PRICE_USDC * CF_USDC / 5.0     = 1.700
    let wethCol = 0.05;   let wethDebt = 50.0   // health = 0.05   * PRICE_WETH * CF_WETH / 50.0    = 2.625
    let wbtcCol = 0.0004; let wbtcDebt = 8.0    // health = 0.0004 * PRICE_WBTC * CF_WBTC / 8.0    = 1.875

    let positions = [
        {"type": MAINNET_FLOW_TOKEN_ID, "amount": flowCol, "storagePath": FLOW_VAULT_STORAGE_PATH, "name": "FLOW", "holder": MAINNET_FLOW_HOLDER},
        {"type": MAINNET_USDF_TOKEN_ID, "amount": usdfCol, "storagePath": MAINNET_USDF_STORAGE_PATH, "name": "USDF", "holder": MAINNET_USDF_HOLDER},
        {"type": MAINNET_USDC_TOKEN_ID, "amount": usdcCol, "storagePath": MAINNET_USDC_STORAGE_PATH, "name": "USDC", "holder": MAINNET_USDC_HOLDER},
        {"type": MAINNET_WETH_TOKEN_ID, "amount": wethCol, "storagePath": MAINNET_WETH_STORAGE_PATH, "name": "WETH", "holder": MAINNET_WETH_HOLDER},
        {"type": MAINNET_WBTC_TOKEN_ID, "amount": wbtcCol, "storagePath": MAINNET_WBTC_STORAGE_PATH, "name": "WBTC", "holder": MAINNET_WBTC_HOLDER}
    ]

    let debts = [flowDebt, usdfDebt, usdcDebt, wethDebt, wbtcDebt]

    var userPids: [UInt64] = []

    for i, position in positions {
        let collateralType = position["type"]! as! String
        let collateralName = position["name"]! as! String
        let collateralAmount = position["amount"]! as! UFix64
        let storagePath = position["storagePath"]! as! StoragePath
        let holder = position["holder"]! as! Test.TestAccount

        // Transfer tokens from holder to user
        transferTokensWithSetup(tokenIdentifier: collateralType, from: holder, to: user, amount: collateralAmount)

        createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: collateralAmount, vaultStoragePath: storagePath, pushToDrawDownSink: false)
        userPids.append(getLastPositionId())

        let price = getOraclePrice(tokenIdentifier: collateralType)
        let value = collateralAmount * price
        log("  Position \(userPids[i]): \(collateralAmount) \(collateralName) collateral (\(value) value)")
    }

    //////////// Borrowing from each position ///////////////////

    log("Borrowing different amounts from each position\n")

    var healths: [UFix128] = []
    for i, debt in debts {
        let pid = userPids[i]
        borrowFromPosition(signer: user, positionId: pid, tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, amount: debt, beFailed: false)

        // Get health factor
        let health = getPositionHealth(pid: pid, beFailed: false)
        healths.append(health)

        log("  Position \(pid): Borrowed \(debt) - Health = \(health)")
    }

    //////////// Test isolation: borrow more from position 2, verify others unchanged ///////////////////

    // userPids[1] is the second user position (USDF collateral)
    let isolationTestPid = userPids[1]
    let additionalDebt = 100.0

    log("Testing isolation by borrowing more from Position \(isolationTestPid)\n")

    log("\n  Action: Borrow 100 more MOET from Position \(isolationTestPid)\n")
    borrowFromPosition(signer: user, positionId: isolationTestPid, tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, amount: additionalDebt, beFailed: false)

    // Get health of all positions after
    var healthsAfterBorrow: [UFix128] = []
    for m in InclusiveRange(0, 4) {
        let h = getPositionHealth(pid: userPids[m], beFailed: false)
        healthsAfterBorrow.append(h)
    }

    // Verify isolation: only position 2 (index 1) should change
    Test.assert(healthsAfterBorrow[0] == healths[0], message: "Position 1 should be unchanged")
    Test.assert(healthsAfterBorrow[1] <  healths[1], message: "Position 2 should decrease")
    Test.assert(healthsAfterBorrow[2] == healths[2], message: "Position 3 should be unchanged")
    Test.assert(healthsAfterBorrow[3] == healths[3], message: "Position 4 should be unchanged")
    Test.assert(healthsAfterBorrow[4] == healths[4], message: "Position 5 should be unchanged")
}

// =============================================================================
// Position Interactions Through Shared Liquidity Pool
//
// Validates cross-position effects mediated by a shared FLOW supply. Position A
// and B compete for the same limited liquidity; a repayment by one restores it
// for the other. A price crash on A's collateral leaves B's health unaffected.
//
// Pool liquidity: 400 MOET LP deposit
//
// Position A: 90 USDC @ 1.00 MOET (CF=0.85), borrow 60 MOET
//   health = 90*1.0*0.85 / 60 = 76.5/60 = 1.275
//   pool remaining = 400 - 60 = 340 MOET
//
// Position B: 500 USDF @ 1.00 MOET (CF=0.85), borrow 340 MOET (drains pool)
//   health = 500*1.0*0.85 / 340 = 425/340 = 1.250
//   pool remaining = 0  →  Position B borrow of 1 MOET fails
//
// Position A repays 40 MOET:
//   debt = 60 - 40 = 20  →  health = 76.5/20 = 3.825
//   pool remaining = 40 MOET
//
// USDC price crash 1.00 MOET → 0.50 MOET (Position A's collateral only):
//   Position A health = 90*0.50*0.85 / 20 = 38.25/20 = 1.913  (still healthy)
//   Position B health: unchanged (USDF collateral unaffected)
//
// Position B borrows 30 MOET from restored pool:
//   health = 500*1.0*0.85 / (340 + 30) = 425/370 = 1.149
// =============================================================================
access(all) fun testPositionInteractionsSharedLiquidity() {
    safeReset()

    log("Testing Position Interactions Through Shared Liquidity Pools\n")

    // Create liquidity provider to deposit FLOW (the shared liquidity pool)
    let lpUser = Test.createAccount()
    let user = Test.createAccount()

    log("Setting up shared liquidity pool with limited capacity\n")
    let liquidityAmount = 400.0
    setupMoetVault(lpUser, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: lpUser.address, amount: liquidityAmount, beFailed: false)

    // LP deposits MOET - this creates the shared liquidity pool
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: lpUser, amount: liquidityAmount, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    log("  Liquidity Provider deposited: \(liquidityAmount) MOET\n")

    //////////// Create Position A with USDC collateral ///////////////////

    let userACollateral = 90.0  // 90 USDC
    log("Creating Position A with \(userACollateral) USDC collateral\n")
    transferTokensWithSetup(tokenIdentifier: MAINNET_USDC_TOKEN_ID, from: MAINNET_USDC_HOLDER, to: user, amount: userACollateral)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: userACollateral, vaultStoragePath: MAINNET_USDC_STORAGE_PATH, pushToDrawDownSink: false)
    let positionA_id = getLastPositionId()

    //////////// Create Position B with USDF collateral ///////////////////

    let userBCollateral = 500.0  // 500 USDF
    log("Creating Position B with \(userBCollateral) USDF collateral\n")
    transferTokensWithSetup(tokenIdentifier: MAINNET_USDF_TOKEN_ID, from: MAINNET_USDF_HOLDER, to: user, amount: userBCollateral)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: userBCollateral, vaultStoragePath: MAINNET_USDF_STORAGE_PATH, pushToDrawDownSink: false)
    let positionB_id = getLastPositionId()

    //////////// 1. Position A borrows heavily, affecting available liquidity ///////////////////

    log("Position A borrows heavily from shared pool\n")
    // Formula: Effective Collateral = (collateralAmount * price) * collateralFactor = (90 × 1.0) × 0.85 = 76.50
    // Max Borrow = 76.50 / 1.1 (minHealth) = 69.55 MOET
    // Health after borrow = 76.50 / 60 = 1.275
    let positionA_borrow1 = 60.0  // Borrow 60 MOET (within max 69.55)
    borrowFromPosition(signer: user, positionId: positionA_id, tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, amount: positionA_borrow1, beFailed: false)

    let healthA_after1 = getPositionHealth(pid: positionA_id, beFailed: false)
    log("  Position A borrowed \(positionA_borrow1) MOET - Health: \(healthA_after1)\n")

    // Check remaining liquidity in pool: liquidityAmount - positionA_borrow1 = 400.0 - 60.0 = 340.0 MOET
    log("  Remaining liquidity in pool: 340.0 MOET\n")

    //////////// 2. Position B borrows successfully from shared pool ///////////////////
    log("Position B borrows from shared pool\n")

    // Formula: Effective Collateral = (collateralAmount * price) * collateralFactor = (500 × 1.0) × 0.85 = 425.00
    // Max Borrow = 425.00 / 1.1 (minHealth) = 386.36 MOET
    let positionB_borrow1 = 340.0  // Borrow 340 MOET (within max 386.36 borrow and 340 remaining liquidity)
    log("  Attempting to borrow \(positionB_borrow1) MOET...")
    borrowFromPosition(signer: user, positionId: positionB_id, tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, amount: positionB_borrow1, beFailed: false)
    log("  Success - Position B borrowed \(positionB_borrow1) MOET")
    let healthB_after1 = getPositionHealth(pid: positionB_id, beFailed: false)
    log("  Position B Health: \(healthB_after1)\n")
    log("  Remaining liquidity in pool: 0.0 MOET\n")

    //////////// 3. Position B tries to exceed max borrowing capacity - expects failure ///////////////////
    log("Position B tries to borrow beyond its capacity - EXPECTS FAILURE\n")

    // Position B can't borrow more because remaining liquidity is 0
    let positionB_borrow2_attempt = 1.0
    log("  Attempting to borrow \(positionB_borrow2_attempt) MOET...")
    borrowFromPosition(signer: user, positionId: positionB_id, tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, amount: positionB_borrow2_attempt, beFailed: true)
    log("  Failed as expected - remaining liquidity is 0\n")

    let healthB_after2 = getPositionHealth(pid: positionB_id, beFailed: false)

    //////////// 4. Position A repayment increases available liquidity ///////////////////
    log("Position A repays debt, freeing liquidity back to pool\n")

    // Position A repays substantial debt by depositing borrowed MOET back
    let repayAmount = 40.0

    // Deposit MOET back to position (repays debt using previously borrowed funds)
    depositToPosition(signer: user, positionID: positionA_id, amount: repayAmount, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, pushToDrawDownSink: false)

    let healthA_after2 = getPositionHealth(pid: positionA_id, beFailed: false)
    log("  Position A repaid \(repayAmount) MOET - Health: \(healthA_after2)\n")
    log("  Remaining liquidity in pool after repayment: \(repayAmount) MOET\n")

    //////////// Verify cross-position effects ///////////////////

    Test.assert(healthA_after2 > healthA_after1, message: "Position A health should improve after repayment")
    Test.assert(healthB_after2 == healthB_after1, message: "Position B health should be unchanged - second borrow attempt failed")


    //////////// 5. Test Position A health change affects Position B's borrowing capacity ///////////////////
    log("Testing how Position A's health deterioration affects Position B\n")

    let healthB_before_priceChange = getPositionHealth(pid: positionB_id, beFailed: false)
    log("  Position B health: \(healthB_before_priceChange)")

    // Crash USDC price (Position A's collateral) −50%
    let usdcCrashPrice = 0.5  // PRICE_USDC * 0.50
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_USDC_TOKEN_ID, price: usdcCrashPrice)

    let healthA_after_crash = getPositionHealth(pid: positionA_id, beFailed: false)
    log("  Position A health after price crash: \(healthA_after_crash)\n")

    // Position A's effective collateral is now: (90 * 0.5) * 0.85 = 38.25
    // Position A's debt is: 60 - 40 = 20 FLOW
    // Position A's health is: 38.25 / 20 = 1.9125
    Test.assert(healthA_after_crash < healthA_after2, message: "Position A health should decrease after collateral price crash")

    // Position B's health should be UNCHANGED (different collateral type)
    let healthB_after_priceChange = getPositionHealth(pid: positionB_id, beFailed: false)
    log("  Position B health after Position A's price crash: \(healthB_after_priceChange)\n")
    Test.assert(healthB_after_priceChange == healthB_before_priceChange, message: "Position B health unaffected by Position A's collateral price change")

    // Position B can still borrow from the shared pool (liquidity is independent of Position A's health)
    // Position B has: 425 effective collateral, 340 borrowed, can borrow up to 46.36 more
    let positionB_borrow3 = 30.0  // Well within remaining capacity (40 MOET available, 46.36 max allowed)
    log("  Position B attempts to borrow \(positionB_borrow3) MOET after Position A's health deterioration...")
    borrowFromPosition(signer: user, positionId: positionB_id, tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, amount: positionB_borrow3, beFailed: false)
    log("  Success - Position B can still borrow despite Position A's poor health\n")

    let healthB_final = getPositionHealth(pid: positionB_id, beFailed: false)
    log("  Position B final health: \(healthB_final)\n")
    Test.assert(healthB_final < healthB_after_priceChange, message: "Position B health decreases from its own borrowing, not Position A's health")

}

// =============================================================================
// Batch Liquidations — 2 Full + 2 Partial in One Transaction
//
// Validates that multiple unhealthy positions can be liquidated atomically in a
// single transaction via the batch DEX helper. Full liquidations bring positions
// above health 1.0; partial liquidations improve health without fully recovering.
//
// Pool liquidity: 600 MOET LP deposit
//
// Positions (all borrow MOET as debt):
//   pid 0:  500 USDF   @ 1.00 MOET  (CF=0.85), borrow 200 → health = 500*1.0*0.85/200    = 2.125
//   pid 1: 0.06 WETH   @ 3500 MOET  (CF=0.75), borrow  90 → health = 0.06*3500*0.75/90   = 1.750
//   pid 2:   80 USDC   @ 1.00 MOET  (CF=0.85), borrow  40 → health = 80*1.0*0.85/40      = 1.700
//   pid 3: 0.0004 WBTC @ 50000 MOET (CF=0.75), borrow  10 → health = 0.0004*50000*0.75/10 = 1.500
//   pid 4:  200 FLOW   @ 1.00 MOET  (CF=0.80), borrow  80 → health = 200*1.0*0.80/80     = 2.000
//
// Price crash:
//   USDF: 1.00 → 0.30 (-70%)  |  WETH: 3500 → 1050 (-70%)
//   USDC: 1.00 → 0.50 (-50%)  |  WBTC: 50000 → 25000 (-50%)  |  FLOW: unchanged
//
// Health after crash:
//   pid 0 (USDF): 500*0.30*0.85/200      = 127.5/200  = 0.638  (unhealthy)
//   pid 1 (WETH): 0.06*1050*0.75/90      = 47.25/90   = 0.525  (unhealthy)
//   pid 2 (USDC): 80*0.50*0.85/40        = 34/40      = 0.850  (unhealthy)
//   pid 3 (WBTC): 0.0004*25000*0.75/10   = 7.5/10     = 0.750  (unhealthy)
//   pid 4 (FLOW): 200*1.00*0.80/80       = 160/80     = 2.000  (healthy, not liquidated)
//
// Batch liquidation (target health 1.05, post ≈1.03 for full, <1.0 for partial):
//   pid 1 FULL:    seize 0.035 WETH, repay 71 FLOW
//     post = (0.06-0.035)*1050*0.75 / (90-71)  = 19.6875/19  ≈ 1.036
//     DEX:  0.035 < 71/1050 = 0.0676
//   pid 0 FULL:    seize 147 USDF,   repay 113 FLOW
//     post = (500-147)*0.30*0.85 / (200-113)   = 90.015/87   ≈ 1.034
//     DEX:  147 < 113/0.30 = 376.7
//   pid 3 PARTIAL: seize 0.00011 WBTC, repay 4 FLOW
//     post = (0.0004-0.00011)*25000*0.75 / (10-4) = 5.4375/6 ≈ 0.906  (still unhealthy)
//     DEX:  0.00011 < 4/25000 = 0.00016
//   pid 2 PARTIAL: seize 17 USDC,     repay 12 FLOW
//     post = (80-17)*0.50*0.85 / (40-12)       = 26.775/28   ≈ 0.956  (still unhealthy)
//     DEX:  17 < 12/0.50 = 24.0
// =============================================================================
access(all) fun testBatchLiquidations() {
    safeReset()

    log("Testing Batch Liquidations of Multiple Positions\n")

    let lpUser = Test.createAccount()
    let user = Test.createAccount()

    // Collateral deposits and target debts (health = col * PRICE * CF / debt):
    let usdfCol = 500.0;  let usdfDebt = 200.0  // health = 500.0  * PRICE_USDF * CF_USDF / 200.0  = 2.125
    let wethCol = 0.06;   let wethDebt = 90.0   // health = 0.06   * PRICE_WETH * CF_WETH / 90.0   = 1.750
    let usdcCol = 80.0;   let usdcDebt = 40.0   // health = 80.0   * PRICE_USDC * CF_USDC / 40.0   = 1.700
    let wbtcCol = 0.0004; let wbtcDebt = 10.0   // health = 0.0004 * PRICE_WBTC * CF_WBTC / 10.0   = 1.500
    let flowCol = 200.0;  let flowDebt = 80.0   // health = 200.0  * PRICE_FLOW * CF_FLOW / 80.0   = 2.000

    // Crashed prices (−70% for USDF/WETH, −50% for USDC/WBTC; FLOW unchanged)
    let usdfCrashPrice = 0.3      // PRICE_USDF * 0.30
    let wethCrashPrice = 1050.0   // PRICE_WETH * 0.30
    let usdcCrashPrice = 0.5      // PRICE_USDC * 0.50
    let wbtcCrashPrice = 25000.0  // PRICE_WBTC * 0.50
    // DEX priceRatio == crashed oracle price (required to pass deviation check)

    // Seize / repay per position (postHealth = (col*CF - seize*P*CF) / (debt - repay))
    let usdfSeize = 147.0;   let usdfRepay = 113.0  // postHealth ≈ 1.034  (full)
    let wethSeize = 0.035;   let wethRepay = 71.0   // postHealth ≈ 1.036  (full)
    let usdcSeize = 17.0;    let usdcRepay = 12.0   // postHealth ≈ 0.956  (partial)
    let wbtcSeize = 0.00011; let wbtcRepay = 4.0    // postHealth ≈ 0.906  (partial)

    // LP deposits lpLiquidity MOET to provide borrowing liquidity
    // (total borrows = usdfDebt+wethDebt+usdcDebt+wbtcDebt+flowDebt = 420 MOET < lpLiquidity)
    let lpLiquidity = 600.0
    setupMoetVault(lpUser, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: lpUser.address, amount: lpLiquidity, beFailed: false)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: lpUser, amount: lpLiquidity, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    // 5 positions with distinct collateral types:
    //
    //  pid | Collateral| Amount      | Borrow   | Crash price | Health after | Action
    //  ----|-----------|-------------|----------|-------------|--------------|--------
    //   1  | USDF      | 500 USDF    | 200 MOET | 0.30 (-70%)| 0.638        | FULL liquidation
    //   2  | WETH      | 0.06 WETH   |  90 MOET | 1050 (-70%)| 0.525        | FULL liquidation
    //   3  | USDC      | 80 USDC     |  40 MOET | 0.50 (-50%)| 0.850        | PARTIAL liquidation
    //   4  | WBTC      | 0.0004 WBTC |  10 MOET | 25000(-50%)| 0.750        | PARTIAL liquidation
    //   5  | FLOW      | 200 FLOW    |  80 MOET | 1.00 (0%)  | 2.000        | NOT liquidated
    //
    log("Creating 5 positions with different collateral types\n")

    let positions = [
        {"type": MAINNET_USDF_TOKEN_ID, "amount": usdfCol, "storagePath": MAINNET_USDF_STORAGE_PATH, "name": "USDF", "holder": MAINNET_USDF_HOLDER, "borrow": usdfDebt},
        {"type": MAINNET_WETH_TOKEN_ID, "amount": wethCol, "storagePath": MAINNET_WETH_STORAGE_PATH, "name": "WETH", "holder": MAINNET_WETH_HOLDER, "borrow": wethDebt},
        {"type": MAINNET_USDC_TOKEN_ID, "amount": usdcCol, "storagePath": MAINNET_USDC_STORAGE_PATH, "name": "USDC", "holder": MAINNET_USDC_HOLDER, "borrow": usdcDebt},
        {"type": MAINNET_WBTC_TOKEN_ID, "amount": wbtcCol, "storagePath": MAINNET_WBTC_STORAGE_PATH, "name": "WBTC", "holder": MAINNET_WBTC_HOLDER, "borrow": wbtcDebt},
        {"type": MAINNET_FLOW_TOKEN_ID, "amount": flowCol, "storagePath": FLOW_VAULT_STORAGE_PATH,   "name": "FLOW", "holder": MAINNET_FLOW_HOLDER, "borrow": flowDebt}
    ]

    var userPids: [UInt64] = []

    for i, position in positions {
        let collateralType = position["type"]! as! String
        let collateralName = position["name"]! as! String
        let collateralAmount = position["amount"]! as! UFix64
        let storagePath = position["storagePath"]! as! StoragePath
        let holder = position["holder"]! as! Test.TestAccount

        transferTokensWithSetup(tokenIdentifier: collateralType, from: holder, to: user, amount: collateralAmount)
        createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: collateralAmount, vaultStoragePath: storagePath, pushToDrawDownSink: false)
        userPids.append(getLastPositionId())
    }

    log("Borrowing MOET from each position\n")
    var healths: [UFix128] = []
    for i, position in positions {
        let pid = userPids[i]
        let borrowAmount = position["borrow"]! as! UFix64
        let collateralName = position["name"]! as! String

        borrowFromPosition(signer: user, positionId: pid, tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, amount: borrowAmount, beFailed: false)

        let health = getPositionHealth(pid: pid, beFailed: false)
        healths.append(health)
        log("  Position \(pid) (\(collateralName)): Borrowed \(borrowAmount) MOET - Health: \(health)")
    }

    // Crash collateral prices. FLOW stays at 1.0 so userPids[4] stays healthy.
    log("\nCrashing collateral prices to trigger liquidations\n")
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_USDF_TOKEN_ID, price: usdfCrashPrice)  // -70%
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_WETH_TOKEN_ID, price: wethCrashPrice)  // -70%
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_USDC_TOKEN_ID, price: usdcCrashPrice)  // -50%
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_WBTC_TOKEN_ID, price: wbtcCrashPrice)  // -50%

    log("\nPosition health after price crash:\n")
    for i in InclusiveRange(0, 4) {
        let pid = userPids[i]
        let health = getPositionHealth(pid: pid, beFailed: false)
        let collateralName = positions[i]["name"]! as! String
        healths[i] = health
        log("  Position \(pid) (\(collateralName)): Health = \(health)")
    }

    // Verify expected health states
    Test.assert(healths[0] < 1.0, message: "USDF position should be unhealthy")
    Test.assert(healths[1] < 1.0, message: "WETH position should be unhealthy")
    Test.assert(healths[2] < 1.0, message: "USDC position should be unhealthy")
    Test.assert(healths[3] < 1.0, message: "WBTC position should be unhealthy")
    Test.assert(healths[4] > 1.0, message: "FLOW position should remain healthy")

    // Verify worst-health ordering: WETH < USDF < WBTC < USDC
    Test.assert(healths[1] < healths[0], message: "WETH should be worse than USDF")
    Test.assert(healths[0] < healths[3], message: "USDF should be worse than WBTC")
    Test.assert(healths[3] < healths[2], message: "WBTC should be worse than USDC")

    // Setup protocol account MOET vault as the DEX output source.
    // priceRatio = Pc_crashed / Pd = post-crash collateral price / MOET price.
    // This must match the oracle prices exactly to pass the DEX/oracle deviation check.
    setupMoetVault(MAINNET_PROTOCOL_ACCOUNT, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: MAINNET_PROTOCOL_ACCOUNT.address, amount: 300.0, beFailed: false)

    log("\nSetting up DEX swappers (priceRatio = post-crash Pc / Pd)\n")
    setMockDexPriceForPair(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        inVaultIdentifier: MAINNET_USDF_TOKEN_ID,
        outVaultIdentifier: MAINNET_MOET_TOKEN_ID,
        vaultSourceStoragePath: MAINNET_MOET_STORAGE_PATH,
        priceRatio: usdfCrashPrice  // usdfCrashPrice USDF / 1.00 MOET
    )
    setMockDexPriceForPair(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        inVaultIdentifier: MAINNET_WETH_TOKEN_ID,
        outVaultIdentifier: MAINNET_MOET_TOKEN_ID,
        vaultSourceStoragePath: MAINNET_MOET_STORAGE_PATH,
        priceRatio: wethCrashPrice  // wethCrashPrice WETH / 1.00 MOET
    )
    setMockDexPriceForPair(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        inVaultIdentifier: MAINNET_USDC_TOKEN_ID,
        outVaultIdentifier: MAINNET_MOET_TOKEN_ID,
        vaultSourceStoragePath: MAINNET_MOET_STORAGE_PATH,
        priceRatio: usdcCrashPrice  // usdcCrashPrice USDC / 1.00 MOET
    )
    setMockDexPriceForPair(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        inVaultIdentifier: MAINNET_WBTC_TOKEN_ID,
        outVaultIdentifier: MAINNET_MOET_TOKEN_ID,
        vaultSourceStoragePath: MAINNET_MOET_STORAGE_PATH,
        priceRatio: wbtcCrashPrice  // wbtcCrashPrice WBTC / 1.00 MOET
    )

    // Liquidator setup: mint MOET for debt repayment (total needed: 71+113+4+12 = 200 MOET)
    // and 1 unit of each collateral token to initialize vault storage paths.
    //
    // Repay amounts derived from: repay = debt - (collat - seize) * CF * P_crashed / H_target
    // let chose target health factor H_target ≈ 1.034 (randomly chosen ~1.03-1.04, close to 1.05 target)
    //
    //   WETH=71:  debt=90,  (0.06-0.035)*0.75*1050 = 19.6875, H≈1.034 → 90  - 19.6875/1.034 ≈ 71
    //   USDF=113: debt=200, (500-147)*0.85*0.3      = 90.015,  H≈1.034 → 200 - 90.015/1.034  ≈ 113
    //   WBTC=4:   partial;  (0.0004-0.00011)*0.75*25000 = 5.4375 → repay=4  → postHealth=5.4375/6≈0.906
    //   USDC=12:  partial;  (80-17)*0.85*0.5            = 26.775 → repay=12 → postHealth=26.775/28≈0.956
    log("\nSetting up liquidator account\n")
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: liquidator.address, amount: 250.0, beFailed: false)
    transferTokensWithSetup(tokenIdentifier: MAINNET_USDF_TOKEN_ID, from: MAINNET_USDF_HOLDER, to: liquidator, amount: 1.0)
    transferTokensWithSetup(tokenIdentifier: MAINNET_WETH_TOKEN_ID, from: MAINNET_WETH_HOLDER, to: liquidator, amount: 0.001)
    transferTokensWithSetup(tokenIdentifier: MAINNET_USDC_TOKEN_ID, from: MAINNET_USDC_HOLDER, to: liquidator, amount: 1.0)
    transferTokensWithSetup(tokenIdentifier: MAINNET_WBTC_TOKEN_ID, from: MAINNET_WBTC_HOLDER, to: liquidator, amount: 0.00001)

    // seize/repay values satisfy three constraints:
    //   1. seize < quote.inAmount         (offer beats DEX price)
    //   2. postHealth <= 1.05             (liquidationTargetHF default)
    //   3. postHealth > pre-liq health    (position improves)
    //
    //   postHealth = (collateral*CF - seize*price*CF) / (debt - repay)
    //   DEX check:  seize < repay / priceRatio   where priceRatio = collateralPrice / debtPrice
    //
    // Full liquidations — bring health up to ~1.03-1.04 (as close to 1.05 target as possible):
    //   pid=WETH: repay 71 MOET, seize 0.035 WETH
    //     postHealth = (47.25 - 0.035*787.5) / (90 - 71) = 19.6875/19 ≈ 1.036
    //     DEX check:  0.035 < 71/1050 = 0.0676
    //   pid=USDF: repay 113 MOET, seize 147 USDF
    //     postHealth = (127.5 - 147*0.255) / (200 - 113) = 90.015/87 ≈ 1.034
    //     DEX check:  147 < 113/0.3 = 376.7
    //
    // Partial liquidations — improve health without reaching 1.05:
    //   pid=WBTC: repay 4 MOET, seize 0.00011 WBTC
    //     postHealth = (7.5 - 0.00011*18750) / (10 - 4) = 5.4375/6 ≈ 0.906
    //     DEX check:  0.00011 < 4/25000 = 0.00016
    //   pid=USDC: repay 12 MOET, seize 17 USDC
    //     postHealth = (34 - 17*0.425) / (40 - 12) = 26.775/28 ≈ 0.956
    //     DEX check:  17 < 12/0.5 = 24

    log("\nExecuting batch liquidation of 4 positions (2 full, 2 partial) in SINGLE transaction...\n")
    let batchPids          = [userPids[0],           userPids[1],           userPids[2],           userPids[3]          ]
    let batchSeizeTypes    = [MAINNET_USDF_TOKEN_ID, MAINNET_WETH_TOKEN_ID, MAINNET_USDC_TOKEN_ID, MAINNET_WBTC_TOKEN_ID]
    let batchSeizeAmounts  = [usdfSeize, wethSeize, usdcSeize, wbtcSeize]
    let batchRepayAmounts  = [usdfRepay, wethRepay, usdcRepay, wbtcRepay]

    batchManualLiquidation(
        admin: MAINNET_PROTOCOL_ACCOUNT,
        pids: batchPids,
        debtVaultIdentifier: MAINNET_MOET_TOKEN_ID,
        seizeVaultIdentifiers: batchSeizeTypes,
        seizeAmounts: batchSeizeAmounts,
        repayAmounts: batchRepayAmounts,
        signer: liquidator
    )

    log("\nVerifying results after batch liquidation:\n")

    // Full liquidations (WETH, USDF): health must cross above 1.0 (healthy again)
    let healthAfterWeth = getPositionHealth(pid: userPids[1], beFailed: false)
    let healthAfterUsdf = getPositionHealth(pid: userPids[0], beFailed: false)
    log("  WETH (FULL):    \(healths[1]) -> \(healthAfterWeth)")
    log("  USDF (FULL):    \(healths[0]) -> \(healthAfterUsdf)")
    Test.assert(healthAfterWeth > 1.0, message: "WETH position should be healthy after full liquidation")
    Test.assert(healthAfterUsdf > 1.0, message: "USDF position should be healthy after full liquidation")

    // Partial liquidations (WBTC, USDC): health must improve but stays below 1.0
    let healthAfterWbtc = getPositionHealth(pid: userPids[3], beFailed: false)
    let healthAfterUsdc = getPositionHealth(pid: userPids[2], beFailed: false)
    log("  WBTC (PARTIAL): \(healths[3]) -> \(healthAfterWbtc)")
    log("  USDC (PARTIAL): \(healths[2]) -> \(healthAfterUsdc)")
    Test.assert(healthAfterWbtc > healths[3], message: "WBTC position health should improve after partial liquidation")
    Test.assert(healthAfterUsdc > healths[2], message: "USDC position health should improve after partial liquidation")

    // FLOW position (userPids[4]): completely unaffected — health is price-independent for FLOW/FLOW
    let healthAfterFlow = getPositionHealth(pid: userPids[4], beFailed: false)
    log("  FLOW (NONE):    \(healths[4]) -> \(healthAfterFlow)")
    Test.assert(healthAfterFlow == healths[4], message: "FLOW position health should be unchanged")
}

// =============================================================================
// Mass Simultaneous Unhealthy Liquidations — 100-Position Stress Test
//
// System-wide stress test: 100 positions across three collateral types all crash
// 40% simultaneously, requiring a chunked batch DEX liquidation of every position.
//
// =============================================================================
access(all) fun testMassUnhealthyLiquidations() {
    safeReset()

    log("=== Stress Test: 100 Positions (USDF/USDC/WBTC) Simultaneously Unhealthy ===\n")

    let lpUser     = Test.createAccount()
    let user       = Test.createAccount()
    let liquidator = Test.createAccount()

    // ── Group index ranges ──────────────────────────────────────────────────────
    // Group A — USDF: indices 0..49 (50 positions)
    let usdfHighStart = 0;  let usdfHighEnd = 24   // high-risk: 25 positions
    let usdfModStart  = 25; let usdfModEnd  = 49   // moderate:  25 positions
    // Group B — USDC: indices 50..94 (45 positions)
    let usdcHighStart = 50; let usdcHighEnd = 72   // high-risk: 23 positions
    let usdcModStart  = 73; let usdcModEnd  = 94   // moderate:  22 positions
    // Group C — WBTC: indices 95..99 (5 positions)
    let wbtcStart = 95; let wbtcEnd = 99

    // Collateral per position (health = colPerPos * PRICE * CF / debt)
    let usdfColPerPos = 10.0    // 50 × usdfColPerPos = 500 USDF transferred
    let usdcColPerPos = 2.0     // 45 × usdcColPerPos = 90  USDC transferred
    let wbtcColPerPos = 0.00009 //  5 × wbtcColPerPos = 0.00045 WBTC transferred

    // Borrow amounts per position
    let usdfHighDebt = 7.0    // health = usdfColPerPos * PRICE_USDF * CF_USDF / usdfHighDebt = 1.214
    let usdfModDebt  = 6.0    // health = usdfColPerPos * PRICE_USDF * CF_USDF / usdfModDebt  = 1.417
    let usdcHighDebt = 1.4    // health = usdcColPerPos * PRICE_USDC * CF_USDC / usdcHighDebt = 1.214
    let usdcModDebt  = 1.2    // health = usdcColPerPos * PRICE_USDC * CF_USDC / usdcModDebt  = 1.417
    let wbtcDebt     = 2.5    // health = wbtcColPerPos * PRICE_WBTC * CF_WBTC / wbtcDebt     = 1.350

    // Crashed prices (−40% across all three collateral types)
    let usdfCrashPrice = 0.6       // PRICE_USDF * 0.60
    let usdcCrashPrice = 0.6       // PRICE_USDC * 0.60
    let wbtcCrashPrice = 30000.0   // PRICE_WBTC * 0.60

    // Seize / repay per position (postHealth = (col*CF - seize*P*CF) / (debt - repay))
    let usdfHighSeize = 4.0;    let usdfHighRepay = 4.0    // postHealth ≈ 1.02
    let usdcHighSeize = 0.8;    let usdcHighRepay = 0.8    // postHealth ≈ 1.02
    let wbtcSeize     = 0.00003; let wbtcRepay    = 1.18   // postHealth ≈ 1.023
    let usdfModSeize  = 4.0;    let usdfModRepay  = 3.0    // postHealth ≈ 1.02
    let usdcModSeize  = 0.8;    let usdcModRepay  = 0.6    // postHealth ≈ 1.02

    let batchChunkSize = 10

    //////////// LP setup ///////////////////

    // LP deposits lpLiquidity MOET — covers the ~397 MOET of total borrows with headroom.
    let lpLiquidity = 450.0
    log("LP depositing \(lpLiquidity) MOET to shared liquidity pool\n")
    setupMoetVault(lpUser, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: lpUser.address, amount: lpLiquidity, beFailed: false)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: lpUser, amount: lpLiquidity, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    //////////// Transfer collateral to user ///////////////////

    // Group A: 50 positions × usdfColPerPos = 500 USDF
    // Group B: 45 positions × usdcColPerPos = 90 USDC
    // Group C:  5 positions × wbtcColPerPos = 0.00045 WBTC
    log("Transferring collateral: 500 USDF + 90 USDC + 0.00045 WBTC\n")
    transferTokensWithSetup(tokenIdentifier: MAINNET_USDF_TOKEN_ID, from: MAINNET_USDF_HOLDER, to: user, amount: 500.0)
    transferTokensWithSetup(tokenIdentifier: MAINNET_USDC_TOKEN_ID, from: MAINNET_USDC_HOLDER, to: user, amount: 90.0)
    transferTokensWithSetup(tokenIdentifier: MAINNET_WBTC_TOKEN_ID, from: MAINNET_WBTC_HOLDER, to: user, amount: 0.00045)

    //////////// Create 100 positions ///////////////////

    var allPids: [UInt64] = []

    // Group A — 50 USDF positions
    log("Creating 50 USDF positions (\(usdfColPerPos) USDF each)...\n")
    for i in InclusiveRange(usdfHighStart, usdfModEnd) {
        createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: usdfColPerPos, vaultStoragePath: MAINNET_USDF_STORAGE_PATH, pushToDrawDownSink: false)
        allPids.append(getLastPositionId())
    }

    // Group B — 45 USDC positions
    log("Creating 45 USDC positions (\(usdcColPerPos) USDC each)...\n")
    for i in InclusiveRange(usdcHighStart, usdcModEnd) {
        createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: usdcColPerPos, vaultStoragePath: MAINNET_USDC_STORAGE_PATH, pushToDrawDownSink: false)
        allPids.append(getLastPositionId())
    }

    // Group C — 5 WBTC positions
    log("Creating 5 WBTC positions (\(wbtcColPerPos) WBTC each)...\n")
    for i in InclusiveRange(wbtcStart, wbtcEnd) {
        createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: wbtcColPerPos, vaultStoragePath: MAINNET_WBTC_STORAGE_PATH, pushToDrawDownSink: false)
        allPids.append(getLastPositionId())
    }

    Test.assert(allPids.length == 100, message: "Expected 100 positions, got \(allPids.length)")

    //////////// Borrow FLOW from each position ///////////////////

    // Group A — USDF positions:
    //   high-risk [usdfHighStart..usdfHighEnd]: borrow usdfHighDebt → health = 1.214
    //   moderate  [usdfModStart..usdfModEnd]:   borrow usdfModDebt  → health = 1.417
    log("Borrowing MOET from 50 USDF positions...\n")
    for i in InclusiveRange(usdfHighStart, usdfHighEnd) {
        borrowFromPosition(signer: user, positionId: allPids[i], tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, amount: usdfHighDebt, beFailed: false)
    }
    for i in InclusiveRange(usdfModStart, usdfModEnd) {
        borrowFromPosition(signer: user, positionId: allPids[i], tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, amount: usdfModDebt, beFailed: false)
    }

    // Group B — USDC positions:
    //   high-risk [usdcHighStart..usdcHighEnd]: borrow usdcHighDebt → health = 1.214
    //   moderate  [usdcModStart..usdcModEnd]:   borrow usdcModDebt  → health = 1.417
    log("Borrowing MOET from 45 USDC positions...\n")
    for i in InclusiveRange(usdcHighStart, usdcHighEnd) {
        borrowFromPosition(signer: user, positionId: allPids[i], tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, amount: usdcHighDebt, beFailed: false)
    }
    for i in InclusiveRange(usdcModStart, usdcModEnd) {
        borrowFromPosition(signer: user, positionId: allPids[i], tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, amount: usdcModDebt, beFailed: false)
    }

    // Group C — WBTC positions:
    //   uniform [wbtcStart..wbtcEnd]: borrow wbtcDebt → health = 1.350
    log("Borrowing MOET from 5 WBTC positions...\n")
    for i in InclusiveRange(wbtcStart, wbtcEnd) {
        borrowFromPosition(signer: user, positionId: allPids[i], tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, amount: wbtcDebt, beFailed: false)
    }

    // Confirm all 100 positions are healthy before the crash
    for i in InclusiveRange(0, 99) {
        let health = getPositionHealth(pid: allPids[i], beFailed: false)
        Test.assert(health > 1.0, message: "Position \(allPids[i]) must be healthy before crash (got \(health))")
    }

    //////////// Simulate 40% price crash across all three collateral types ///////////////////

    // USDF/USDC: PRICE_USDF → usdfCrashPrice (-40%)  |  WBTC: PRICE_WBTC → wbtcCrashPrice (-40%)
    //
    // Health after crash:
    //   USDF high: (usdfColPerPos×usdfCrashPrice×CF_USDF)/usdfHighDebt = 0.729
    //   USDF mod:  (usdfColPerPos×usdfCrashPrice×CF_USDF)/usdfModDebt  = 0.850
    //   USDC high: (usdcColPerPos×usdcCrashPrice×CF_USDC)/usdcHighDebt = 0.729
    //   USDC mod:  (usdcColPerPos×usdcCrashPrice×CF_USDC)/usdcModDebt  = 0.850
    //   WBTC:      (wbtcColPerPos×wbtcCrashPrice×CF_WBTC)/wbtcDebt     = 0.810
    log("All three collateral types crash 40% simultaneously\n")
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_USDF_TOKEN_ID, price: usdfCrashPrice)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_USDC_TOKEN_ID, price: usdcCrashPrice)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_WBTC_TOKEN_ID, price: wbtcCrashPrice)

    // Capture post-crash health by token type and verify all positions are unhealthy
    var usdfHealths: [UFix128] = []
    var usdcHealths: [UFix128] = []
    var wbtcHealths: [UFix128] = []

    for i in InclusiveRange(0, 49) {
        let h = getPositionHealth(pid: allPids[i], beFailed: false)
        usdfHealths.append(h)
        Test.assert(h < 1.0, message: "USDF pos \(allPids[i]) must be unhealthy (got \(h))")
    }
    for i in InclusiveRange(50, 94) {
        let h = getPositionHealth(pid: allPids[i], beFailed: false)
        usdcHealths.append(h)
        Test.assert(h < 1.0, message: "USDC pos \(allPids[i]) must be unhealthy (got \(h))")
    }
    for i in InclusiveRange(95, 99) {
        let h = getPositionHealth(pid: allPids[i], beFailed: false)
        wbtcHealths.append(h)
        Test.assert(h < 1.0, message: "WBTC pos \(allPids[i]) must be unhealthy (got \(h))")
    }

    // Verify risk ordering: high-risk (more debt) → worse health than moderate
    // usdfHealths[0]=high-risk, usdfHealths[25]=first moderate; usdcHealths[0]=high-risk, usdcHealths[23]=first moderate
    Test.assert(usdfHealths[0] < usdfHealths[25], message: "USDF high-risk must be worse than moderate")
    Test.assert(usdcHealths[0] < usdcHealths[23], message: "USDC high-risk must be worse than moderate")

    log("  USDF high: \(usdfHealths[0]) (≈0.729)  mod: \(usdfHealths[25]) (≈0.850)\n")
    log("  USDC high: \(usdcHealths[0]) (≈0.729)  mod: \(usdcHealths[23]) (≈0.850)\n")
    log("  WBTC:      \(wbtcHealths[0]) (≈0.810)\n")
    log("  All 100 positions confirmed unhealthy — proceeding to batch liquidation\n")

    //////////// DEX setup ///////////////////

    // Three DEX pairs (all source MOET from MAINNET_PROTOCOL_ACCOUNT's vault):
    //   USDF→MOET at priceRatio=usdfCrashPrice
    //   USDC→MOET at priceRatio=usdcCrashPrice
    //   WBTC→MOET at priceRatio=wbtcCrashPrice
    //
    // Total DEX MOET: 25×usdfHighRepay + 25×usdfModRepay + 23×usdcHighRepay + 22×usdcModRepay + 5×wbtcRepay
    //               = 100 + 75 + 18.4 + 13.2 + 5.90 = 212.50; mint 230 for headroom
    log("Configuring DEX pairs: USDF→MOET, USDC→MOET, WBTC→MOET\n")
    setupMoetVault(MAINNET_PROTOCOL_ACCOUNT, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: MAINNET_PROTOCOL_ACCOUNT.address, amount: 230.0, beFailed: false)
    setMockDexPriceForPair(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        inVaultIdentifier: MAINNET_USDF_TOKEN_ID,
        outVaultIdentifier: MAINNET_MOET_TOKEN_ID,
        vaultSourceStoragePath: MAINNET_MOET_STORAGE_PATH,
        priceRatio: usdfCrashPrice
    )
    setMockDexPriceForPair(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        inVaultIdentifier: MAINNET_USDC_TOKEN_ID,
        outVaultIdentifier: MAINNET_MOET_TOKEN_ID,
        vaultSourceStoragePath: MAINNET_MOET_STORAGE_PATH,
        priceRatio: usdcCrashPrice
    )
    setMockDexPriceForPair(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        inVaultIdentifier: MAINNET_WBTC_TOKEN_ID,
        outVaultIdentifier: MAINNET_MOET_TOKEN_ID,
        vaultSourceStoragePath: MAINNET_MOET_STORAGE_PATH,
        priceRatio: wbtcCrashPrice
    )

    //////////// Build batch parameters (ordered worst health first) ///////////////////
    //
    // Seize/repay parameters (ordered worst health first):
    //   USDF high  [usdfHighStart..usdfHighEnd]: seize usdfHighSeize, repay usdfHighRepay  post=1.02
    //   USDC high  [usdcHighStart..usdcHighEnd]: seize usdcHighSeize, repay usdcHighRepay  post=1.02
    //   WBTC       [wbtcStart..wbtcEnd]:         seize wbtcSeize,     repay wbtcRepay      post=1.023
    //   USDF mod   [usdfModStart..usdfModEnd]:   seize usdfModSeize,  repay usdfModRepay   post=1.02
    //   USDC mod   [usdcModStart..usdcModEnd]:   seize usdcModSeize,  repay usdcModRepay   post=1.02
    var batchPids:    [UInt64] = []
    var batchSeize:   [String] = []
    var batchAmounts: [UFix64] = []
    var batchRepay:   [UFix64] = []

    // USDF high-risk [usdfHighStart..usdfHighEnd]
    for i in InclusiveRange(usdfHighStart, usdfHighEnd) {
        batchPids.append(allPids[i])
        batchSeize.append(MAINNET_USDF_TOKEN_ID)
        batchAmounts.append(usdfHighSeize)
        batchRepay.append(usdfHighRepay)
    }
    // USDC high-risk [usdcHighStart..usdcHighEnd]
    for i in InclusiveRange(usdcHighStart, usdcHighEnd) {
        batchPids.append(allPids[i])
        batchSeize.append(MAINNET_USDC_TOKEN_ID)
        batchAmounts.append(usdcHighSeize)
        batchRepay.append(usdcHighRepay)
    }
    // WBTC uniform [wbtcStart..wbtcEnd]
    for i in InclusiveRange(wbtcStart, wbtcEnd) {
        batchPids.append(allPids[i])
        batchSeize.append(MAINNET_WBTC_TOKEN_ID)
        batchAmounts.append(wbtcSeize)
        batchRepay.append(wbtcRepay)
    }
    // USDF moderate [usdfModStart..usdfModEnd]
    for i in InclusiveRange(usdfModStart, usdfModEnd) {
        batchPids.append(allPids[i])
        batchSeize.append(MAINNET_USDF_TOKEN_ID)
        batchAmounts.append(usdfModSeize)
        batchRepay.append(usdfModRepay)
    }
    // USDC moderate [usdcModStart..usdcModEnd]
    for i in InclusiveRange(usdcModStart, usdcModEnd) {
        batchPids.append(allPids[i])
        batchSeize.append(MAINNET_USDC_TOKEN_ID)
        batchAmounts.append(usdcModSeize)
        batchRepay.append(usdcModRepay)
    }

    Test.assert(batchPids.length == 100, message: "Expected 100 batch entries, got \(batchPids.length)")

    //////////// Batch liquidation — 100 positions in chunks of 10 ///////////////////

    // Setup liquidator vaults for seized collateral tokens (required to receive seized amounts).
    transferTokensWithSetup(tokenIdentifier: MAINNET_USDF_TOKEN_ID, from: MAINNET_USDF_HOLDER, to: liquidator, amount: 1.0)
    transferTokensWithSetup(tokenIdentifier: MAINNET_USDC_TOKEN_ID, from: MAINNET_USDC_HOLDER, to: liquidator, amount: 1.0)
    transferTokensWithSetup(tokenIdentifier: MAINNET_WBTC_TOKEN_ID, from: MAINNET_WBTC_HOLDER, to: liquidator, amount: 0.00001)

    // Split into chunks of 10 to stay within the computation limit (single tx of 100 exceeds it).
    // DEX sources MOET from MAINNET_PROTOCOL_ACCOUNT's vault; liquidator receives seized collateral.
    log("Liquidating all 100 positions via DEX in chunks of 10...\n")
    batchLiquidateViaMockDex(
        admin: MAINNET_PROTOCOL_ACCOUNT,
        pids: batchPids,
        debtVaultIdentifier: MAINNET_MOET_TOKEN_ID,
        seizeVaultIdentifiers: batchSeize,
        seizeAmounts: batchAmounts,
        repayAmounts: batchRepay,
        chunkSize: batchChunkSize,
        signer: liquidator
    )

    //////////// Verification ///////////////////

    // All 100 positions must have improved and be healthy again
    log("Verifying all 100 positions recovered...\n")

    // USDF [0..49]
    for i in InclusiveRange(0, 49) {
        let h = getPositionHealth(pid: allPids[i], beFailed: false)
        Test.assert(h > usdfHealths[i], message: "USDF pos \(allPids[i]) health must improve: \(usdfHealths[i]) → \(h)")
        Test.assert(h > 1.0, message: "USDF pos \(allPids[i]) must be healthy again (got \(h))")
    }
    // USDC [50..94]
    for i in InclusiveRange(0, 44) {
        let pidIdx = i + 50
        let h = getPositionHealth(pid: allPids[pidIdx], beFailed: false)
        Test.assert(h > usdcHealths[i], message: "USDC pos \(allPids[pidIdx]) health must improve: \(usdcHealths[i]) → \(h)")
        Test.assert(h > 1.0, message: "USDC pos \(allPids[pidIdx]) must be healthy again (got \(h))")
    }
    // WBTC [95..99]
    for i in InclusiveRange(0, 4) {
        let pidIdx = i + 95
        let h = getPositionHealth(pid: allPids[pidIdx], beFailed: false)
        Test.assert(h > wbtcHealths[i], message: "WBTC pos \(allPids[pidIdx]) health must improve: \(wbtcHealths[i]) → \(h)")
        Test.assert(h > 1.0, message: "WBTC pos \(allPids[pidIdx]) must be healthy again (got \(h))")
    }

    // Protocol solvency: FLOW reserve must remain positive after mass liquidation
    let reserveBalance = getReserveBalance(vaultIdentifier: MAINNET_MOET_TOKEN_ID)
    log("Protocol MOET reserve after mass liquidation: \(reserveBalance)\n")
    Test.assert(reserveBalance > 0.0, message: "Protocol must remain solvent (positive MOET reserve) after mass liquidation")
}
