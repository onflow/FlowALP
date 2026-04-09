#test_fork(network: "mainnet-fork", height: 142528994)

import Test
import BlockchainHelpers

import "FlowToken"
import "FungibleToken"
import "MOET"
import "FlowALPv0"
import "DeFiActions"
import "MockOracle"
import "FlowALPEvents"
import "FlowALPMath"

import "test_helpers.cdc"

access(all) let MAINNET_PROTOCOL_ACCOUNT = Test.getAccount(MAINNET_PROTOCOL_ACCOUNT_ADDRESS)
access(all) let MAINNET_USDF_HOLDER = Test.getAccount(MAINNET_USDF_HOLDER_ADDRESS)
access(all) let MAINNET_WETH_HOLDER = Test.getAccount(MAINNET_WETH_HOLDER_ADDRESS)

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

    createAndStorePool(signer: MAINNET_PROTOCOL_ACCOUNT, defaultTokenIdentifier: MAINNET_MOET_TOKEN_ID, beFailed: false)

    // Set initial oracle prices (baseline)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_FLOW_TOKEN_ID, price: 1.0)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_USDF_TOKEN_ID, price: 1.0)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_WETH_TOKEN_ID, price: 2000.0)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_MOET_TOKEN_ID, price: 1.0)

    // Add FLOW as supported token (80% CF, 90% BF)
    addSupportedTokenZeroRateCurve(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_FLOW_TOKEN_ID,
        collateralFactor: 0.8,
        borrowFactor: 0.9,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // Add USDF as supported token (90% CF, 95% BF)
    addSupportedTokenZeroRateCurve(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_USDF_TOKEN_ID,
        collateralFactor: 0.9,
        borrowFactor: 0.95,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // Add WETH as supported token (75% CF, 85% BF)
    addSupportedTokenZeroRateCurve(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_WETH_TOKEN_ID,
        collateralFactor: 0.75,
        borrowFactor: 0.85,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    snapshot = getCurrentBlockHeight()
}

// =============================================================================
// Price feed failure
// =============================================================================

// test_oracle_nil_price tests scenario when the oracle has no price for a token, any operation that requires
// pricing (health check, borrow, withdraw) must revert.
// The PriceOracle interface allows returning nil, but the Pool force-unwraps
// with `self.priceOracle.price(ofToken: type)!` — so nil triggers a panic.
access(all)
fun test_oracle_nil_price() {
    safeReset()

    // STEP 1: Setup user with FLOW position
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)

    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: 1000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    let openEvents = Test.eventsOfType(Type<FlowALPEvents.Opened>())
    let pid = (openEvents[openEvents.length - 1] as! FlowALPEvents.Opened).pid

    // STEP 2: Remove FLOW price from oracle
    let res = setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_FLOW_TOKEN_ID, price: nil)

    // STEP 3: Attempting to read position health should revert
    // The pool's positionHealth() calls `self.priceOracle.price(ofToken: type)!` which panics on nil.
    // because the oracle returns nil for FLOW and the pool force-unwraps it
    let health = getPositionHealth(pid: pid, beFailed: true)
}

// =============================================================================
// Invalid price data
// =============================================================================

// -----------------------------------------------------------------------------
/// Verifies that the protocol rejects a position when the PriceOracle returns a zero price. 
/// A zero price would cause division-by-zero in health calculations
/// and incorrectly value collateral at $0. The PriceOracle interface
/// guarantees `result! > 0.0`, so setting price to 0.0 must cause the oracle to revert.
// -----------------------------------------------------------------------------
access(all)
fun test_oracle_zero_price() {
    safeReset()

    // STEP 1: Attempt to set FLOW price to 0.0
    // The PriceOracle interface postcondition requires price > 0.0.
    // The MockOracle's price() function should revert on zero.
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_FLOW_TOKEN_ID, price: 0.0)

    // STEP 2: Setup user with FLOW position
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)

    // STEP 3: Attempting to create position should fail
    grantBetaPoolParticipantAccess(MAINNET_PROTOCOL_ACCOUNT, user)

    let openRes = _executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [1000.0, FLOW_VAULT_STORAGE_PATH, false],
        user
    )
    Test.expect(openRes, Test.beFailed())
    Test.assertError(openRes, errorMessage: "PriceOracle must return a price greater than 0.0 if available")
}

// -----------------------------------------------------------------------------
// Oracle Returns Extremely Small Price (Near-Zero)
// A price like 0.00000001 is technically > 0 and passes
// the interface check, but may cause overflow or extreme health values.
// Tests that the protocol handles micro-prices correctly.
// -----------------------------------------------------------------------------
access(all)
fun test_oracle_near_zero_price_extreme_health() {
    safeReset()

    // STEP 1: Setup MOET LP + user with FLOW collateral + MOET debt
    let moetLp = Test.createAccount()
    setupMoetVault(moetLp, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: moetLp.address, amount: 50000.0, beFailed: false)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: moetLp, amount: 50000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)

    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: 1000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    let openEvents = Test.eventsOfType(Type<FlowALPEvents.Opened>())
    let pid = (openEvents[openEvents.length - 1] as! FlowALPEvents.Opened).pid

    // Borrow 500 MOET
    borrowFromPosition(signer: user, positionId: pid, tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, amount: 500.0, beFailed: false)

    // STEP 2: Crash FLOW to near-zero ($0.00000001)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_FLOW_TOKEN_ID, price: 0.00000001)

    // Collateral: 
    //   FLOW: 1000 * $0.00000001 * 0.8 = $0.000008
    // Debt: 
    //  MOET: 500 * $1.00 / 1.0 = $500
    //
    // Health = $0.000008 / $500 = 0.000000016 (unhealty, essentially zero)
    let expectedHealth: UFix128 = 0.000000016
    let health = getPositionHealth(pid: pid, beFailed: false)
    Test.assertEqual(expectedHealth, health)

    // Position should be liquidatable
    let isLiquidatable = getIsLiquidatable(pid: pid)
    Test.assertEqual(true, isLiquidatable)
}

// -----------------------------------------------------------------------------
// Oracle Returns Extremely Large Price (UFix64 Max)
// Tests that extremely large prices don't overflow internal UFix128 math.
// A WETH price of UFix64.max should be within safe bounds.
// -----------------------------------------------------------------------------
access(all)
fun test_oracle_very_large_price_no_overflow() {
    safeReset()

    // STEP 1: Setup user with WETH position
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    var res = setupGenericVault(user, vaultIdentifier: MAINNET_WETH_TOKEN_ID)
    Test.expect(res, Test.beSucceeded())

    let wethAmount: UFix64 = 0.001
    transferFungibleTokens(tokenIdentifier: MAINNET_WETH_TOKEN_ID, from: MAINNET_WETH_HOLDER, to: user, amount: wethAmount)

    let tinyDeposit = 0.00000001
    setMinimumTokenBalancePerPosition(signer: MAINNET_PROTOCOL_ACCOUNT, tokenTypeIdentifier: MAINNET_WETH_TOKEN_ID, minimum: tinyDeposit)

    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: wethAmount, vaultStoragePath: MAINNET_WETH_STORAGE_PATH, pushToDrawDownSink: false)

    let openEvents = Test.eventsOfType(Type<FlowALPEvents.Opened>())
    let pid = (openEvents[openEvents.length - 1] as! FlowALPEvents.Opened).pid

    // STEP 2: Set WETH to extreme price (UFix64.max)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_WETH_TOKEN_ID, price: UFix64.max)

    // Collateral: 
    //   WETH: 0.001 * $100,000,000 * 0.75 = $75,000
    // Debt: 0$ 
    //
    // Health = infinite (UFix128.max)
    let health = getPositionHealth(pid: pid, beFailed: false)
    Test.assertEqual(CEILING_HEALTH, health)

    // Verify available balance doesn't overflow
    let available = getAvailableBalance(pid: pid, vaultIdentifier: MAINNET_WETH_TOKEN_ID, pullFromTopUpSource: false, beFailed: false)
    Test.assertEqual(wethAmount, available)
}

// =============================================================================
// DEX-Oracle price deviation utility function
// =============================================================================

// -----------------------------------------------------------------------------
// dexOraclePriceDeviationInRange — Boundary Cases
// Tests the pure helper function that computes deviation in basis points.
// -----------------------------------------------------------------------------
access(all)
fun test_dex_oracle_deviation_boundary_exact_threshold() {
    safeReset()

    // Exactly at 300 bps (3%) — should pass
    // Oracle: $1.00, DEX: $1.03 → deviation = |1.03-1.00|/1.00 = 3.0% = 300 bps
    var res = FlowALPMath.dexOraclePriceDeviationInRange(dexPrice: 1.03, oraclePrice: 1.0, maxDeviationBps: 300)
    Test.assertEqual(true, res)

    // One basis point over — should fail
    // Oracle: $1.00, DEX: $1.0301 → deviation = 3.01% = 301 bps
    res = FlowALPMath.dexOraclePriceDeviationInRange(dexPrice: 1.0301, oraclePrice: 1.0, maxDeviationBps: 300)
    Test.assertEqual(false, res)

    // DEX below oracle — same threshold applies
    // Oracle: $1.00, DEX: $0.97 → deviation = |0.97-1.00|/0.97 = 3.09% = 309 bps
    res = FlowALPMath.dexOraclePriceDeviationInRange(dexPrice: 0.97, oraclePrice: 1.0, maxDeviationBps: 300)
    Test.assertEqual(false, res)

    // DEX: $0.971 → deviation = |0.971-1.00|/0.971 = 2.98% = 298 bps
    res = FlowALPMath.dexOraclePriceDeviationInRange(dexPrice: 0.971, oraclePrice: 1.0, maxDeviationBps: 300)
    Test.assertEqual(true, res)

    // Equal prices — zero deviation — always passes
    res = FlowALPMath.dexOraclePriceDeviationInRange(dexPrice: 1.0, oraclePrice: 1.0, maxDeviationBps: 0)
    Test.assertEqual(true, res)
}

// -----------------------------------------------------------------------------
// Governance Adjusts DEX Deviation Threshold
// Tests that governance can tighten or loosen the circuit breaker.
// A tighter threshold (e.g., 100 bps = 1%) should block liquidations
// that would be allowed under the default 300 bps.
// -----------------------------------------------------------------------------
access(all)
fun test_governance_tightens_dex_deviation_threshold() {
    safeReset()

    // STEP 1: Setup MOET LP + unhealthy position
    let moetLp = Test.createAccount()
    setupMoetVault(moetLp, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: moetLp.address, amount: 50000.0, beFailed: false)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: moetLp, amount: 50000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)

    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: 1000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    let openEvents = Test.eventsOfType(Type<FlowALPEvents.Opened>())
    let pid = (openEvents[openEvents.length - 1] as! FlowALPEvents.Opened).pid

    borrowFromPosition(signer: user, positionId: pid, tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, amount: 700.0, beFailed: false)

    // Make position unhealthy
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_FLOW_TOKEN_ID, price: 0.70)

    // DEX price within default 3% threshold but outside 1%
    // Oracle: $0.70, DEX: $0.685 → deviation = |0.685-0.70|/0.685 = 2.19%
    setMockDexPriceForPair(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        inVaultIdentifier: MAINNET_FLOW_TOKEN_ID,
        outVaultIdentifier: MAINNET_MOET_TOKEN_ID,
        vaultSourceStoragePath: MOET.VaultStoragePath,
        priceRatio: 0.685
    )

    // STEP 2: Tighten threshold to 100 bps (1%)
    setDexLiquidationConfig(signer: MAINNET_PROTOCOL_ACCOUNT, dexOracleDeviationBps: 100)

    // STEP 3: Liquidation should now fail (2.19% > 1% threshold)
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: liquidator.address, amount: 500.0, beFailed: false)

    let liqRes = manualLiquidation(
        admin: MAINNET_PROTOCOL_ACCOUNT,
        signer: liquidator,
        pid: pid,
        debtVaultIdentifier: MAINNET_MOET_TOKEN_ID,
        seizeVaultIdentifier: MAINNET_FLOW_TOKEN_ID,
        seizeAmount: 140.0,
        repayAmount: 100.0,
    )
    Test.expect(liqRes, Test.beFailed())
    Test.assertError(liqRes, errorMessage: "DEX/oracle price deviation too large")
}


// =============================================================================
// Extreme price scenarios
// =============================================================================

// -----------------------------------------------------------------------------
// Flash Crash: 50% Price Drop in a Single Block
// FLOW drops from $1.00 to $0.50 between two operations.
// Tests that a previously healthy multi-collateral position becomes
// immediately liquidatable, and that liquidation works correctly at the
// post-crash price.
// -----------------------------------------------------------------------------
access(all)
fun test_flash_crash_triggers_liquidation() {
    safeReset()

    // STEP 1: Setup MOET liquidity provider
    let moetLp = Test.createAccount()
    setupMoetVault(moetLp, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: moetLp.address, amount: 50000.0, beFailed: false)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: moetLp, amount: 50000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    // STEP 2: Setup user with FLOW collateral + moderate MOET debt
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)

    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: 1000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    let openEvents = Test.eventsOfType(Type<FlowALPEvents.Opened>())
    let pid = (openEvents[openEvents.length - 1] as! FlowALPEvents.Opened).pid

    borrowFromPosition(signer: user, positionId: pid, tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, amount: 600.0, beFailed: false)

    // Collateral: 
    //   FLOW: 1000 * $1.00 * 0.8 = $800
    // Total collateral: $800
    // Debt: 
    //   MOET: 600 * $1.00 / 1.0 = $600
    // Total debt: $600
    //
    // Health = $800 / $600 = 1.333... (healthy)

    let healthBefore = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(healthBefore > 1.0, message: "Position should be healthy before crash")

    // STEP 3: Flash crash — FLOW drops 50% ($1.00 → $0.50)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_FLOW_TOKEN_ID, price: 0.50)
    setMockDexPriceForPair(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        inVaultIdentifier: MAINNET_FLOW_TOKEN_ID,
        outVaultIdentifier: MAINNET_MOET_TOKEN_ID,
        vaultSourceStoragePath: MOET.VaultStoragePath,
        priceRatio: 0.50
    )

    // New position state:
    // Collateral: 
    //   FLOW: 1000 * $0.5 * 0.8 = $400
    // Total collateral: $400
    // Debt: 
    //   MOET: 600 * $1.00 / 1.0 = $600
    // Total debt: $600
    //
    // Health = $400 / $600 = 0.666... (unhealthy)
    let healthAfterCrash = getPositionHealth(pid: pid, beFailed: false)
    let expectedHealthAfterCrash: UFix128 = 0.666666666666666666666666
    Test.assertEqual(expectedHealthAfterCrash, healthAfterCrash)
    Test.assert(healthAfterCrash < 1.0, message: "Position should be unhealthy after 50% crash")

    // STEP 4: Verify the position is liquidatable
    let isLiquidatable = getIsLiquidatable(pid: pid)
    Test.assertEqual(true, isLiquidatable)

    // STEP 5: Execute liquidation
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: liquidator.address, amount: 1000.0, beFailed: false)

    // Repay 100 MOET, seize FLOW
    // DEX quote: 100 / 0.50 = 200 FLOW
    // Liquidator offers: 195 FLOW (better than DEX)
    let liqRes = manualLiquidation(
        admin: MAINNET_PROTOCOL_ACCOUNT,
        signer: liquidator,
        pid: pid,
        debtVaultIdentifier: MAINNET_MOET_TOKEN_ID,
        seizeVaultIdentifier: MAINNET_FLOW_TOKEN_ID,
        seizeAmount: 195.0,
        repayAmount: 100.0,
    )
    Test.expect(liqRes, Test.beSucceeded())

    // Verify post-liquidation state
    let details = getPositionDetails(pid: pid, beFailed: false)
    let flowCredit = getCreditBalanceForType(details: details, vaultType: Type<@FlowToken.Vault>())
    Test.assertEqual(805.0, flowCredit) // 1000 - 195

    let moetDebit = getDebitBalanceForType(details: details, vaultType: Type<@MOET.Vault>())
    Test.assertEqual(500.0, moetDebit) // 600 - 100
}

// -----------------------------------------------------------------------------
// Flash Pump: 100% Price Increase in a Single Block
// FLOW doubles from $1.00 to $2.00.
// Tests that a position immediately reflects the new higher health.
// Typical collateral factors are not sufficient to protect against sudden and dramatic price moves.
// FlowALP relies on Oracle implementations to smooth out underlying price information or return no price
// at all when price information sources disagree. 
// -----------------------------------------------------------------------------
access(all)
fun test_flash_pump_increase_doubles_health() {
    safeReset()

    // STEP 1: Setup MOET liquidity provider
    let moetLp = Test.createAccount()
    setupMoetVault(moetLp, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: moetLp.address, amount: 50000.0, beFailed: false)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: moetLp, amount: 50000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    // STEP 2: Setup user with FLOW collateral and MOET debt
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)

    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: 1000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    let openEvents = Test.eventsOfType(Type<FlowALPEvents.Opened>())
    let pid = (openEvents[openEvents.length - 1] as! FlowALPEvents.Opened).pid

    borrowFromPosition(signer: user, positionId: pid, tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, amount: 500.0, beFailed: false)

    // Collateral: 
    //   FLOW: 1000 * $1.00 * 0.8 = $800
    // Total collateral: $800
    //
    // Debt: 
    //   MOET: 500 * $1.00 / 1.0 = $500
    // Total debt: $500
    //
    // Health = $800 / $500 = 1.6 (healthy)

    let healthBefore = getPositionHealth(pid: pid, beFailed: false)
    let expectedHealthBefore: UFix128 = 1.6
    Test.assertEqual(expectedHealthBefore, healthBefore)

    // STEP 3: Flash pump — FLOW doubles ($1.00 → $2.00)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_FLOW_TOKEN_ID, price: 2.0)

    // New position state:
    // Collateral: 
    //   FLOW: 1000 * $2.00 * 0.8 = $1600
    // Total collateral: $1600
    //
    // Debt: 
    //   MOET: 500 * $1.00 / 1.0 = $500
    // Total debt: $500
    //
    // Health = $1600 / $500 = 3.2 (healthy)

    let healthAfterPump = getPositionHealth(pid: pid, beFailed: false)
    let expectedHealthAfterPump: UFix128 = 3.2
    Test.assertEqual(expectedHealthAfterPump, healthAfterPump)

    // STEP 4: User tries to borrow max at pumped price
    // Max borrow = ($1600 / 1.1) * 1.0 / $1.0 - $500 = ~954.545 additional MOET
    let availableMoet = getAvailableBalance(pid: pid, vaultIdentifier: MAINNET_MOET_TOKEN_ID, pullFromTopUpSource: false, beFailed: false)
    Test.assert(availableMoet > 900.0, message: "User should be able to borrow significantly more at pumped price")

    // STEP 5: User borrows at pumped price, then price corrects back
    borrowFromPosition(signer: user, positionId: pid, tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, amount: 900.0, beFailed: false)

    // Price corrects back to $1.00
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_FLOW_TOKEN_ID, price: 1.0)

    // Position after correction:
    // Collateral: 
    //   FLOW: 1000 * $1.00 * 0.8 = $800
    // Total collateral: $800
    //
    // Debt: 
    //   MOET: (500+900) * $1.00 / 1.0 = $1400
    // Total debt: $1400
    //
    // Health = $800 / $1400 = 0.571... (severely unhealthy)

    // This demonstrates the danger of flash pump exploitation:
    // The user borrowed at inflated prices and is now underwater.
    // The protocol's collateral factors provide some buffer, but cannot
    // fully protect against 100% price swings.
    // The protocol also relies on Oracle implementations to smooth out price information or report no price
    // when information sources disagree.
    let healthAfterCorrection = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(healthAfterCorrection < 1.0, message: "Position should be underwater after pump-and-dump scenario")
}