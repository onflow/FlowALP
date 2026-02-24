#test_fork(network: "mainnet", height: 142528994)

import Test
import BlockchainHelpers

import "FlowToken"
import "FungibleToken"
import "MOET"
import "FlowALPv0"

import "test_helpers.cdc"

access(all) let MAINNET_PROTOCOL_ACCOUNT = Test.getAccount(MAINNET_PROTOCOL_ACCOUNT_ADDRESS)
access(all) let MAINNET_USDF_HOLDER = Test.getAccount(MAINNET_USDF_HOLDER_ADDRESS)
access(all) let MAINNET_WETH_HOLDER = Test.getAccount(MAINNET_WETH_HOLDER_ADDRESS)
access(all) let MAINNET_WBTC_HOLDER = Test.getAccount(MAINNET_WBTC_HOLDER_ADDRESS)

// -----------------------------------------------------------------------------
// Multi-Collateral Position Tests with EVM Bridged Tokens
// -----------------------------------------------------------------------------

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
    var err = Test.deployContract(
        name: "DeFiActionsUtils",
        path: "../../FlowActions/cadence/contracts/utils/DeFiActionsUtils.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    err = Test.deployContract(
        name: "FlowALPMath",
        path: "../lib/FlowALPMath.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    err = Test.deployContract(
        name: "DeFiActions",
        path: "../../FlowActions/cadence/contracts/interfaces/DeFiActions.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "MockOracle",
        path: "../contracts/mocks/MockOracle.cdc",
        arguments: [MAINNET_MOET_TOKEN_ID]
    )
    Test.expect(err, Test.beNil())

    // Deploy FungibleTokenConnectors
    err = Test.deployContract(
        name: "FungibleTokenConnectors",
        path: "../../FlowActions/cadence/contracts/connectors/FungibleTokenConnectors.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "MockDexSwapper",
        path: "../contracts/mocks/MockDexSwapper.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

     err = Test.deployContract(
        name: "FlowALPv0",
        path: "../contracts/FlowALPv0.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    createAndStorePool(signer: MAINNET_PROTOCOL_ACCOUNT, defaultTokenIdentifier: MAINNET_MOET_TOKEN_ID, beFailed: false)

    // Set oracle prices
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_FLOW_TOKEN_ID, price: 1.0)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_USDF_TOKEN_ID, price: 1.0)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_WETH_TOKEN_ID, price: 2000.0)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_MOET_TOKEN_ID, price: 1.0)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_WBTC_TOKEN_ID, price: 40000.0)
    
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

    // Add WBTC (70% CF, 80% BF)
    addSupportedTokenZeroRateCurve(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_WBTC_TOKEN_ID,
        collateralFactor: 0.7,
        borrowFactor: 0.8,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )
    
    snapshot = getCurrentBlockHeight()
}

// -----------------------------------------------------------------------------
// Comprehensive Multi-Collateral Position Test
// Tests a single position with FLOW + USDF + WETH collateral
// Covers: weighted collateral factors, health calculations, and asset correlations
// -----------------------------------------------------------------------------
access(all)
fun test_multi_collateral_position() {
    safeReset()
    
    // STEP 1: Setup MOET liquidity provider for borrowing
    let moetLp = Test.createAccount()
    setupMoetVault(moetLp, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: moetLp.address, amount: 50000.0, beFailed: false)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: moetLp, amount: 50000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    
    let FLOWAmount = 1000.0
    let USDFAmount = 500.0
    let WETHAmount = 0.05
    // STEP 2: Setup test user with all three tokens
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    var res = setupGenericVault(user, vaultIdentifier: MAINNET_USDF_TOKEN_ID)
    Test.expect(res, Test.beSucceeded())
    res = setupGenericVault(user, vaultIdentifier: MAINNET_WETH_TOKEN_ID)
    Test.expect(res, Test.beSucceeded())
    
    transferFlowTokens(to: user, amount: FLOWAmount)
    transferFungibleTokens(
        tokenIdentifier: MAINNET_USDF_TOKEN_ID,
        from: MAINNET_USDF_HOLDER,
        to: user,
        amount: USDFAmount
    )
    transferFungibleTokens(
        tokenIdentifier: MAINNET_WETH_TOKEN_ID,
        from: MAINNET_WETH_HOLDER,
        to: user,
        amount: WETHAmount
    )
    
    // STEP 3: Create position with FLOW collateral
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: FLOWAmount, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
    
    let openEvents = Test.eventsOfType(Type<FlowALPv0.Opened>())
    let pid = (openEvents[openEvents.length - 1] as! FlowALPv0.Opened).pid

    // Health should be infinite (no debt)
    var health = getPositionHealth(pid: pid, beFailed: false)
    Test.assertEqual(CEILING_HEALTH, health)

    // STEP 4: Add USDF collateral
    depositToPosition(signer: user, positionID: pid, amount: USDFAmount, vaultStoragePath: MAINNET_USDF_STORAGE_PATH, pushToDrawDownSink: false)
    // STEP 5: Add WETH collateral
    depositToPosition(signer: user, positionID: pid, amount: WETHAmount, vaultStoragePath: MAINNET_WETH_STORAGE_PATH, pushToDrawDownSink: false)
    
    // Collateral (effectiveCollateral = balance * price * collateralFactor):
    //   FLOW: 1000 * $1.00 * 0.8 = $800
    //   USDF: 500 * $1.00 * 0.9 = $450
    //   WETH: 0.05 * $2000 * 0.75 = $75
    // Total collateral: $1325
    //
    // Debt: $0
    
    // Verify all balances
    let details = getPositionDetails(pid: pid, beFailed: false)
    let flowCredit = getCreditBalanceForType(details: details, vaultType: Type<@FlowToken.Vault>())
    Test.assertEqual(FLOWAmount, flowCredit)
    let usdfCredit = getCreditBalanceForType(details: details, vaultType: CompositeType(MAINNET_USDF_TOKEN_ID)!)
    Test.assertEqual(USDFAmount, usdfCredit)
    let wethCredit = getCreditBalanceForType(details: details, vaultType: CompositeType(MAINNET_WETH_TOKEN_ID)!)
    Test.assertEqual(WETHAmount, wethCredit)
    
    // Health still infinite (no debt)
    health = getPositionHealth(pid: pid, beFailed: false)
    Test.assertEqual(CEILING_HEALTH, health)
    
    // STEP 6: Test weighted collateral factors - calculate max borrowing
    // Max borrow = (effectiveCollateral / minHealth) * borrowFactor / price
    //    MOET: maxBorrow = ($1325 / 1.1) * 1.0 / $1.00 = 1204.54545455 MOET
    let expectedMaxMoet: UFix64 = 1204.54545455
    let availableMoet = getAvailableBalance(pid: pid, vaultIdentifier: MAINNET_MOET_TOKEN_ID, pullFromTopUpSource: false, beFailed: false)
    Test.assertEqual(expectedMaxMoet, availableMoet)
    
    // STEP 7: Borrow 1204 MOET to create debt
    borrowFromPosition(signer: user, positionId: pid, tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, amount: 1204.0, beFailed: false)

    // Position state after borrow:
    // Collateral (effectiveCollateral = balance * price * collateralFactor):
    //   FLOW: 1000 * $1.00 * CF(0.8) = $800
    //   USDF: 500 * $1.00 * CF(0.9) = $450
    //   WETH: 0.05 * $2000 * CF(0.75) = $75
    // Total collateral: $1325
    //
    // Debt (effectiveDebt = balance * price / borrowFactor):
    //   MOET: 1204 * $1.00 / BF(1.0) = $1204
    // Total debt: $1204
    //
    // Health = $1325 / $1204 = 1.100498338870431893687707
    
    health = getPositionHealth(pid: pid, beFailed: false)
    let expectedHealth: UFix128 = 1.100498338870431893687707
    Test.assertEqual(expectedHealth, health)
}

// -----------------------------------------------------------------------------
// Cross-Asset Borrowing (FLOW → USDF)
// Deposit FLOW, borrow USDF
// -----------------------------------------------------------------------------
access(all)
fun test_cross_asset_flow_to_usdf_borrowing() {
    safeReset()
    
    // STEP 1: Setup USDF liquidity provider
    let usdfLp = Test.createAccount()
    var res = setupGenericVault(usdfLp, vaultIdentifier: MAINNET_USDF_TOKEN_ID)
    Test.expect(res, Test.beSucceeded())
    
    transferFungibleTokens(
        tokenIdentifier: MAINNET_USDF_TOKEN_ID,
        from: MAINNET_USDF_HOLDER,
        to: usdfLp,
        amount: 10000.0
    )
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: usdfLp, amount: 10000.0, vaultStoragePath: MAINNET_USDF_STORAGE_PATH, pushToDrawDownSink: false)
    
    // STEP 2: Setup test user with FLOW
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    res = setupGenericVault(user, vaultIdentifier: MAINNET_USDF_TOKEN_ID)
    Test.expect(res, Test.beSucceeded())
    
    let flowAmount: UFix64 = 1000.0
    transferFlowTokens(to: user, amount: flowAmount)
    
    // STEP 3: Create position with FLOW collateral
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: flowAmount, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
    
    let openEvents = Test.eventsOfType(Type<FlowALPv0.Opened>())
    let pid = (openEvents[openEvents.length - 1] as! FlowALPv0.Opened).pid
    
    // Collateral (effectiveCollateral = balance * price * collateralFactor):
    //   FLOW: 1000 * $1.00 * CF(0.8) = $800
    // Max borrow = (effectiveCollateral / minHealth) * borrowFactor / price
    //   Max USDF: ($800 / 1.1) * 0.95 / $1.00 = ~ 690.909 USDF
    
    // STEP 4: Borrow USDF against FLOW collateral
    let usdfBorrowAmount: UFix64 = 600.0
    borrowFromPosition(signer: user, positionId: pid, tokenTypeIdentifier: MAINNET_USDF_TOKEN_ID, vaultStoragePath: MAINNET_USDF_STORAGE_PATH, amount: usdfBorrowAmount, beFailed: false)
    
    // Position state:
    // Collateral (effectiveCollateral = balance * price * collateralFactor):
    //   FLOW: 1000 * $1.00 * CF(0.8) = $800
    //
    // Debt (effectiveDebt = balance * price / borrowFactor):
    //   USDF: 600 * $1.00 / BF(0.95) = $631.58
    //
    // Health = $800 / $631.58 = 1.266666666666666666666666
    
    let health = getPositionHealth(pid: pid, beFailed: false)
    let expectedHealth: UFix128 = 1.266666666666666666666666
    
    Test.assertEqual(expectedHealth, health)
    
    // Verify balances
    let details = getPositionDetails(pid: pid, beFailed: false)
    let flowCredit = getCreditBalanceForType(details: details, vaultType: Type<@FlowToken.Vault>())
    Test.assertEqual(flowAmount, flowCredit)
    
    let usdfDebit = getDebitBalanceForType(details: details, vaultType: CompositeType(MAINNET_USDF_TOKEN_ID)!)
    Test.assertEqual(usdfBorrowAmount, usdfDebit)
}

// -----------------------------------------------------------------------------
// Multi-Step Cross-Asset Borrowing (FLOW → USDF → WETH)
// Step 1: Deposit FLOW, borrow USDF
// Step 2: Deposit borrowed USDF, borrow WETH
// -----------------------------------------------------------------------------
access(all)
fun test_cross_asset_flow_usdf_weth_borrowing() {
    safeReset()
    
    // STEP 1: Setup liquidity providers for USDF and WETH
    let usdfLp = Test.createAccount()
    var res = setupGenericVault(usdfLp, vaultIdentifier: MAINNET_USDF_TOKEN_ID)
    Test.expect(res, Test.beSucceeded())
    transferFungibleTokens(tokenIdentifier: MAINNET_USDF_TOKEN_ID, from: MAINNET_USDF_HOLDER, to: usdfLp, amount: 10000.0)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: usdfLp, amount: 10000.0, vaultStoragePath: MAINNET_USDF_STORAGE_PATH, pushToDrawDownSink: false)
    
    let wethLp = Test.createAccount()
    res = setupGenericVault(wethLp, vaultIdentifier: MAINNET_WETH_TOKEN_ID)
    Test.expect(res, Test.beSucceeded())
    transferFungibleTokens(tokenIdentifier: MAINNET_WETH_TOKEN_ID, from: MAINNET_WETH_HOLDER, to: wethLp, amount: 0.05)
    
    let tinyDeposit = 0.00000001
    setMinimumTokenBalancePerPosition(signer: MAINNET_PROTOCOL_ACCOUNT, tokenTypeIdentifier: MAINNET_WETH_TOKEN_ID, minimum: tinyDeposit)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: wethLp, amount: 0.05, vaultStoragePath: MAINNET_WETH_STORAGE_PATH, pushToDrawDownSink: false)

    // STEP 2: Setup user with FLOW
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    res = setupGenericVault(user, vaultIdentifier: MAINNET_USDF_TOKEN_ID)
    Test.expect(res, Test.beSucceeded())
    res = setupGenericVault(user, vaultIdentifier: MAINNET_WETH_TOKEN_ID)
    Test.expect(res, Test.beSucceeded())
    
    let flowAmount: UFix64 = 1000.0
    transferFlowTokens(to: user, amount: flowAmount)
    
    // STEP 3: Create position with FLOW
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: flowAmount, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
    
    let openEvents = Test.eventsOfType(Type<FlowALPv0.Opened>())
    let pid = (openEvents[openEvents.length - 1] as! FlowALPv0.Opened).pid
    
    // Collateral (effectiveCollateral = balance * price * collateralFactor): 
    //   FLOW: 1000 * $1.00 * 0.8 = $800
    // Total collateral: $800
    //
    // Max borrow = (effectiveCollateral / minHealth) * borrowFactor / price
    //   Max USDF: ($800 / 1.1) * 0.95 = 690.90909091 USDF
    
    let usdfBorrowAmount: UFix64 = 500.0
    borrowFromPosition(signer: user, positionId: pid, tokenTypeIdentifier: MAINNET_USDF_TOKEN_ID, vaultStoragePath: MAINNET_USDF_STORAGE_PATH, amount: usdfBorrowAmount, beFailed: false)
    
    var health = getPositionHealth(pid: pid, beFailed: false)
   // Test.assertEqual(CEILING_HEALTH, health)
    
    // STEP 4: Deposit borrowed USDF as collateral
    depositToPosition(signer: user, positionID: pid, amount: usdfBorrowAmount, vaultStoragePath: MAINNET_USDF_STORAGE_PATH, pushToDrawDownSink: false)
    
    // New collateral (effectiveCollateral = balance * price * collateralFactor):
    //   FLOW: 1000 * $1.00 * 0.8 = $800
    //   USDF: 500 * $1.00 * 0.9 = $450
    //   Total collateral: $1250
    //
    // Debt (effectiveDebt = balance * price / borrowFactor): 
    //   USDF: 500 * $1.00 / 0.9 = $450
    
    health = getPositionHealth(pid: pid, beFailed: false)
    Test.assertEqual(CEILING_HEALTH, health)
    
    // Max borrow = (effectiveCollateral / minHealth) * borrowFactor / price
    // Max WETH: ($1250 / 1.1) * 0.85 / $2000 = ~0.48295454545 WETH
    // But we only have 0.05 WETH on pool available, so borrow 0.04
    let wethBorrowAmount: UFix64 = 0.04
    borrowFromPosition(signer: user, positionId: pid, tokenTypeIdentifier: MAINNET_WETH_TOKEN_ID, vaultStoragePath: MAINNET_WETH_STORAGE_PATH, amount: wethBorrowAmount, beFailed: false)
    
    // Final position:
    // Collateral (effectiveCollateral = balance * price * collateralFactor):
    //   FLOW: 1000 * $1.00 * 0.8 = $800
    //   USDF: 500 * $1.00 * 0.9 = $450
    //
    // Debt (effectiveDebt = balance * price / borrowFactor):
    //   USDF: 500 * $1.00 / 0.9 = $450
    //   WETH: 0.04 * $2000 / 0.85 = $94.12
    //
    // After netting USDF (credit 500 - debt 500 = 0):
    //
    // Collateral:   
    //   FLOW: 1000 * $1.00 * 0.8 = $800 
    // Debt:
    //   WETH: 0.04 * $2000 / 0.85 = $94.117647059
    //
    // Health = $800 / $94.117647059 = 8.5
    
    health = getPositionHealth(pid: pid, beFailed: false)
    let expectedHealth: UFix128 = 8.5
    Test.assertEqual(expectedHealth, health)
}

// -----------------------------------------------------------------------------
// Complex Four-Step Cross-Asset Chain (FLOW → USDF → WETH → WBTC)
// Complete swap path through protocol
// -----------------------------------------------------------------------------
access(all)
fun test_cross_asset_chain() {
    safeReset()
    
    // STEP 1: Setup all liquidity providers
    // USDF LP
    let usdfLp = Test.createAccount()
    var res = setupGenericVault(usdfLp, vaultIdentifier: MAINNET_USDF_TOKEN_ID)
    Test.expect(res, Test.beSucceeded())
    transferFungibleTokens(tokenIdentifier: MAINNET_USDF_TOKEN_ID, from: MAINNET_USDF_HOLDER, to: usdfLp, amount: 1000.0)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: usdfLp, amount: 1000.0, vaultStoragePath: MAINNET_USDF_STORAGE_PATH, pushToDrawDownSink: false)
    
    // WETH LP (0.05 WETH available)
    let wethLp = Test.createAccount()
    res = setupGenericVault(wethLp, vaultIdentifier: MAINNET_WETH_TOKEN_ID)
    Test.expect(res, Test.beSucceeded())
    transferFungibleTokens(tokenIdentifier: MAINNET_WETH_TOKEN_ID, from: MAINNET_WETH_HOLDER, to: wethLp, amount: 0.05)

    let tinyDeposit = 0.0000001
    setMinimumTokenBalancePerPosition(signer: MAINNET_PROTOCOL_ACCOUNT, tokenTypeIdentifier: MAINNET_WETH_TOKEN_ID, minimum: tinyDeposit)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: wethLp, amount: 0.05, vaultStoragePath: MAINNET_WETH_STORAGE_PATH, pushToDrawDownSink: false)
    
    // WBTC LP (0.0004 WBTC available)
    let wbtcLp = Test.createAccount()
    res = setupGenericVault(wbtcLp, vaultIdentifier: MAINNET_WBTC_TOKEN_ID)
    Test.expect(res, Test.beSucceeded())
    transferFungibleTokens(tokenIdentifier: MAINNET_WBTC_TOKEN_ID, from: MAINNET_WBTC_HOLDER, to: wbtcLp, amount: 0.0004)

    setMinimumTokenBalancePerPosition(signer: MAINNET_PROTOCOL_ACCOUNT, tokenTypeIdentifier: MAINNET_WBTC_TOKEN_ID, minimum: tinyDeposit)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: wbtcLp, amount: 0.0004, vaultStoragePath: MAINNET_WBTC_STORAGE_PATH, pushToDrawDownSink: false)
        
    // STEP 2: Setup user with FLOW position
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    res = setupGenericVault(user, vaultIdentifier: MAINNET_USDF_TOKEN_ID)
    Test.expect(res, Test.beSucceeded())
    res = setupGenericVault(user, vaultIdentifier: MAINNET_WETH_TOKEN_ID)
    Test.expect(res, Test.beSucceeded())
    res = setupGenericVault(user, vaultIdentifier: MAINNET_WBTC_TOKEN_ID)
    Test.expect(res, Test.beSucceeded())
    
    let flowAmount: UFix64 = 1000.0
    transferFlowTokens(to: user, amount: flowAmount)
    
    // STEP 3: Create position and execute complete chain
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: flowAmount, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
    
    let openEvents = Test.eventsOfType(Type<FlowALPv0.Opened>())
    let pid = (openEvents[openEvents.length - 1] as! FlowALPv0.Opened).pid
    
    // Collateral (effectiveCollateral = balance * price * collateralFactor): 
    //   FLOW: 1000 * $1.00 * 0.8 = $800
    // Max borrow ((effectiveCollateral / minHealth) * borrowFactor / price):
    //   Max USDF = ($800 / 1.1) * 0.95 / $1.0 = ~690.9090 USDF
    
    // Step 4: Borrow USDF
    let usdfBorrow: UFix64 = 600.0
    borrowFromPosition(signer: user, positionId: pid, tokenTypeIdentifier: MAINNET_USDF_TOKEN_ID, vaultStoragePath: MAINNET_USDF_STORAGE_PATH, amount: usdfBorrow, beFailed: false)
    
    // Step 5: Deposit USDF, borrow WETH (limited by available liquidity)
    depositToPosition(signer: user, positionID: pid, amount: usdfBorrow, vaultStoragePath: MAINNET_USDF_STORAGE_PATH, pushToDrawDownSink: false)
    
    // Collateral (effectiveCollateral = balance * price * collateralFactor): 
    //   FLOW: 1000 * $1.00 * 0.8 = $800
    // Total collateral: $800
    //
    // Debt: 
    //   USDF (0 netted)
    //
    // Max borrow = (effectiveCollateral / minHealth) * borrowFactor / price
    //   Max WETH = ($800 / 1.1) * 0.85 / $2000 = ~0.30909090 WETH

    // limited by available liquidity: 0.0005 max
    let wethBorrow: UFix64 = 0.0005 
    borrowFromPosition(signer: user, positionId: pid, tokenTypeIdentifier: MAINNET_WETH_TOKEN_ID, vaultStoragePath: MAINNET_WETH_STORAGE_PATH, amount: wethBorrow, beFailed: false)
    
    // Step 6: Deposit WETH, borrow WBTC
    depositToPosition(signer: user, positionID: pid, amount: wethBorrow, vaultStoragePath: MAINNET_WETH_STORAGE_PATH, pushToDrawDownSink: false)
    
    // Collateral (effectiveCollateral = balance * price * collateralFactor): 
    //   FLOW: 1000 * $1.00 * 0.8 = $800
    // Total collateral: $800
    //
    // Debt: 
    //   USDF (0 netted)
    //   WETH (0 netted)
    //
    // Max borrow = (effectiveCollateral / minHealth) * borrowFactor / price
    //   Max WBTC = ($800 / 1.1) * 0.8 / $40000 = ~0.014545 WBTC

    // Limited by available liquidity (0.0004 total)
    let wbtcBorrow: UFix64 = 0.0004
    borrowFromPosition(signer: user, positionId: pid, tokenTypeIdentifier: MAINNET_WBTC_TOKEN_ID, vaultStoragePath: MAINNET_WBTC_STORAGE_PATH, amount: wbtcBorrow, beFailed: false)
    
    // Final position:
    // Collateral (effectiveCollateral = balance * price * collateralFactor):
    //   FLOW: 1000 * $1.00 * 0.8 = $800
    // Total collateral: $800
    //
    // Debt (effectiveDebt = balance * price / borrowFactor):
    //   WBTC: 0.0004 * $40000 / 0.8 = $20
    //
    // Health = $800 / $20 = 40
    
    let finalHealth = getPositionHealth(pid: pid, beFailed: false)
    let expectedHealth: UFix128 = 40.0

    Test.assertEqual(expectedHealth, finalHealth)
    
    // Verify all balances
    let details = getPositionDetails(pid: pid, beFailed: false)
    let flowCredit = getCreditBalanceForType(details: details, vaultType: CompositeType(MAINNET_FLOW_TOKEN_ID)!)
    Test.assertEqual(1000.0, flowCredit)
    
    let usdfCredit = getCreditBalanceForType(details: details, vaultType: CompositeType(MAINNET_USDF_TOKEN_ID)!)
    Test.assertEqual(0.0, usdfCredit)
    
    let wethCredit = getCreditBalanceForType(details: details, vaultType: CompositeType(MAINNET_WETH_TOKEN_ID)!)
    Test.assertEqual(0.0, wethCredit)
    
    let wbtcDebit = getDebitBalanceForType(details: details, vaultType: CompositeType(MAINNET_WBTC_TOKEN_ID)!)
    Test.assertEqual(0.0004, wbtcDebit)
}

// -----------------------------------------------------------------------------
// Asset Price Correlation and Uncorrelated Movements
// Tests how health changes when different assets move independently
// Price: FLOW +10%, USDF -5%, WETH +20%
// -----------------------------------------------------------------------------
access(all)
fun test_multi_asset_uncorrelated_price_movements() {
    safeReset()
    
    // STEP 1: Setup liquidity providers for MOET
    let moetLp = Test.createAccount()
    setupMoetVault(moetLp, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: moetLp.address, amount: 50000.0, beFailed: false)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: moetLp, amount: 50000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    
    // STEP 2: Setup test user with FLOW, USDF, and WETH
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    var res = setupGenericVault(user, vaultIdentifier: MAINNET_USDF_TOKEN_ID)
    Test.expect(res, Test.beSucceeded())
    res = setupGenericVault(user, vaultIdentifier: MAINNET_WETH_TOKEN_ID)
    Test.expect(res, Test.beSucceeded())
    
    let flowAmount: UFix64 = 1000.0
    let usdfAmount: UFix64 = 500.0
    let wethAmount: UFix64 = 0.05
    
    transferFlowTokens(to: user, amount: flowAmount)
    transferFungibleTokens(tokenIdentifier: MAINNET_USDF_TOKEN_ID, from: MAINNET_USDF_HOLDER, to: user, amount: usdfAmount)
    transferFungibleTokens(tokenIdentifier: MAINNET_WETH_TOKEN_ID, from: MAINNET_WETH_HOLDER, to: user, amount: wethAmount)
    
    // STEP 3: Create position with FLOW collateral
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: flowAmount, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
    
    let openEvents = Test.eventsOfType(Type<FlowALPv0.Opened>())
    let pid = (openEvents[openEvents.length - 1] as! FlowALPv0.Opened).pid
    
    // STEP 4: Add USDF and WETH collateral
    depositToPosition(signer: user, positionID: pid, amount: usdfAmount, vaultStoragePath: MAINNET_USDF_STORAGE_PATH, pushToDrawDownSink: false)
    depositToPosition(signer: user, positionID: pid, amount: wethAmount, vaultStoragePath: MAINNET_WETH_STORAGE_PATH, pushToDrawDownSink: false)
    
    // Collateral (effectiveCollateral = balance * price * collateralFactor):
    //   FLOW: 1000 * $1.00 * CF(0.8) = $800
    //   USDF: 500 * $1.00 * CF(0.9) = $450
    //   WETH: 0.05 * $2000 * CF(0.75) = $75
    // Total collateral: $1325

    // STEP 5: Borrow 1000 MOET to create debt
    borrowFromPosition(signer: user, positionId: pid, tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, amount: 1000.0, beFailed: false)
    
    // Position state after borrow at initial prices:
    // Collateral (effectiveCollateral = balance * price * collateralFactor):
    // Total collateral: $1325 (unchanged)
    //
    // Debt (effectiveDebt = balance * price / borrowFactor):
    //   MOET: 1000 * $1.00 / BF(1.0) = $1000
    // 
    // Health = $1325 / $1000 = 1.325
    
    let initialHealth = getPositionHealth(pid: pid, beFailed: false)
    let expectedInitialHealth: UFix128 = 1.325
    Test.assertEqual(expectedInitialHealth, initialHealth)
    
    // STEP 6: Test uncorrelated price movements

    // FLOW: $1.00 → $1.10 (+10%)
    // USDF: $1.00 → $0.95 (-5%)
    // WETH: $2000 → $2400 (+20%)
    // MOET: $1.00 (stable)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_FLOW_TOKEN_ID, price: 1.10)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_USDF_TOKEN_ID, price: 0.95)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_WETH_TOKEN_ID, price: 2400.0)
    // MOET remains at $1.00
    
    // New position state with changed prices:
    // Collateral (effectiveCollateral = balance * price * collateralFactor):
    //   FLOW: 1000 * $1.10 * CF(0.8) = $880 (was $800, +$80)
    //   USDF: 500 * $0.95 * CF(0.9) = $427.50 (was $450, -$22.50)
    //   WETH: 0.05 * $2400 * CF(0.75) = $90 (was $75, +$15)
    // Total collateral: $1397.50 (was $1325, +$72.50)
    //
    // Debt (unchanged because MOET price is stable):
    //   MOET: 1000 * $1.00 / BF(1.0) = $1000
    //
    // Health = $1397.50 / $1000 = 1.3975
    
    let healthAfterChange = getPositionHealth(pid: pid, beFailed: false)
    let expectedHealthAfterChange: UFix128 = 1.3975
    
    Test.assertEqual(expectedHealthAfterChange, healthAfterChange)
}

// -----------------------------------------------------------------------------
// Partial Collateral Withdrawal
// -----------------------------------------------------------------------------
access(all)
fun test_multi_asset_partial_withdrawal() {
    safeReset()
    
    // STEP 1: Setup MOET liquidity provider
    // We need someone else to deposit MOET so there's liquidity for borrowing
    let moetLp = Test.createAccount()
    setupMoetVault(moetLp, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: moetLp.address, amount: 10000.0, beFailed: false)
    
    // MOET LP deposits MOET (creates MOET credit balance = provides liquidity)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: moetLp, amount: 10000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    
    // STEP 2: Setup test user
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: user.address, amount: 500.0, beFailed: false)
    
    // STEP 3: Create position with FLOW
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: 1000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
    
    let openEvents = Test.eventsOfType(Type<FlowALPv0.Opened>())
    let pid = (openEvents[openEvents.length - 1] as! FlowALPv0.Opened).pid
    
    // STEP 4: Add MOET collateral
    depositToPosition(signer: user, positionID: pid, amount: 500.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    
    // Initial collateral (effectiveCollateral = balance * price * collateralFactor):
    //   FLOW: 1000 * $1.00 * 0.8 = $800
    //   MOET: 500 * $1.00 * 1.0 = $500
    // Total collateral: $1300
    
    // STEP 5: Borrow 400 MOET
    borrowFromPosition(signer: user, positionId: pid, tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, amount: 400.0, beFailed: false)
    
    // Position state after borrow:
    // MOET borrow (netting):
    //  1) Had 500 MOET credit
    //  2) Borrowed 400 MOET
    //  3) Result: 100 MOET credit remains (500 - 400)
    //
    // Collateral (effectiveCollateral = balance * price * collateralFactor):
    //   FLOW: 1000 * $1.00 * CF(0.8) = $800
    //   MOET: 100 * $1.00 * CF(1.0) = $100
    // Total collateral: $900
    //
    // Debt (effectiveDebt = balance * price / borrowFactor):
    //   FLOW: $0
    //   MOET: $0
    //
    // Health = $900 / $0 = ∞ (UFix128.max)
    
    let initialHealth = getPositionHealth(pid: pid, beFailed: false)
    
    // STEP 6: Withdraw 300 FLOW (partial withdrawal)
    borrowFromPosition(signer: user, positionId: pid, tokenTypeIdentifier: MAINNET_FLOW_TOKEN_ID, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, amount: 300.0, beFailed: false)
    
    // Position state after FLOW withdrawal:
    // FLOW withdrawal mechanics:
    //  1) Had 1000 FLOW credit
    //  2) Withdrew 300 FLOW
    //  3) Result: 700 FLOW credit remains (1000 - 300)
    //
    // Collateral (effectiveCollateral = balance * price * collateralFactor):
    //   FLOW: 700 * $1.00 * CF(0.8) = $560 (was $800)
    //   MOET: 100 * $1.00 * CF(1.0) = $100
    // Total collateral: $660
    //
    // Debt (effectiveDebt = balance * price / borrowFactor):
    //   FLOW: $0
    //   MOET: $0
    //
    // Health = $660 / $0 = (no debt)
    
    let newHealth = getPositionHealth(pid: pid, beFailed: false)
    
    // Both healths are infinite (no debt), so they're equal
    // We can't test health decrease when there's no debt
    // Instead verify the collateral decreased
    let details = getPositionDetails(pid: pid, beFailed: false)
    let remainingFlow = getCreditBalanceForType(details: details, vaultType: Type<@FlowToken.Vault>())
    Test.assertEqual(700.0, remainingFlow)
    
    let remainingMoet = getCreditBalanceForType(details: details, vaultType: Type<@MOET.Vault>())
    Test.assertEqual(100.0, remainingMoet)

    Test.assertEqual(newHealth, initialHealth)
}

// -----------------------------------------------------------------------------
// Cross-Collateral Borrowing Capacity
// Tests borrowing capacity when using multiple collateral types
// Key insight: When borrowing the same token you have as collateral.
// To test true cross-collateral borrowing, borrow a different token.
// -----------------------------------------------------------------------------
access(all)
fun test_cross_collateral_borrowing_capacity() {
    safeReset()
    
    // STEP 1: Setup MOET and USDF liquidity providers
    let moetLp = Test.createAccount()
    setupMoetVault(moetLp, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: moetLp.address, amount: 10000.0, beFailed: false)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: moetLp, amount: 10000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: MAINNET_USDF_HOLDER, amount: 10000.0, vaultStoragePath: MAINNET_USDF_STORAGE_PATH, pushToDrawDownSink: false)
    
    // STEP 2: Setup test user with FLOW + MOET collateral
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    var res = setupGenericVault(user, vaultIdentifier: MAINNET_USDF_TOKEN_ID)
    Test.expect(res, Test.beSucceeded())
    transferFlowTokens(to: user, amount: 1000.0)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: user.address, amount: 900.0, beFailed: false)
    
    // STEP 3: Create position with FLOW + MOET collateral
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: 1000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
    
    let openEvents = Test.eventsOfType(Type<FlowALPv0.Opened>())
    let pid = (openEvents[openEvents.length - 1] as! FlowALPv0.Opened).pid
    
    depositToPosition(signer: user, positionID: pid, amount: 900.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    
    // Collateral (effectiveCollateral = balance * price * collateralFactor):
    //   FLOW: 1000 * $1.00 * CF(0.8) = $800
    //   MOET: 900 * $1.00 * CF(1.0) = $900
    // Total collateral: $1700
    //
    // Debt: $0
    //
    // Health: ∞ (no debt)
    
    // STEP 4: Calculate position's balance available for withdrawal for each token
    // maxBorrow = (effectiveCollateral / minHealth) * borrowFactor / price
    // Using default minHealth = 1.1
    //
    //  MOET (credit token) -> 900 MOET (credit amount, not calculated from health). This is withdrawal, not true borrowing
    //  USDF (no balance, different from collateral): maxBorrow = ($1700 / 1.1) * 0.95 / $1.00 = ~1468.18181818 USDF
    //  FLOW (credit token): -> 1000 FLOW. This is withdrawal, not true borrowing
    
    // Test MOET borrowing (limited by credit amount)
    let expectedMaxMoet: UFix64 = 900.0
    let availableMoet = getAvailableBalance(pid: pid, vaultIdentifier: MAINNET_MOET_TOKEN_ID, pullFromTopUpSource: false, beFailed: false)
    Test.assertEqual(expectedMaxMoet, availableMoet)
    
    // Test USDF borrowing (true cross-collateral calculation)
    let expectedMaxUsdf: UFix64 = 1468.18181818
    let availableUsdf = getAvailableBalance(pid: pid, vaultIdentifier: MAINNET_USDF_TOKEN_ID, pullFromTopUpSource: false, beFailed: false)
    Test.assertEqual(expectedMaxUsdf, availableUsdf)
    
    // Test FLOW borrowing (limited by credit amount)
    let expectedMaxFlow: UFix64 = 1000.0
    let availableFlow = getAvailableBalance(pid: pid, vaultIdentifier: MAINNET_FLOW_TOKEN_ID, pullFromTopUpSource: false, beFailed: false)
    Test.assertEqual(expectedMaxFlow, availableFlow)
}

// -----------------------------------------------------------------------------
// Multi-Asset Position Liquidation - Liquidator Chooses Collateral
// Position with 3 collateral types (FLOW, USDF, WETH) and 2 debt types (MOET, USDF)
// Liquidator selects which collateral to seize
// -----------------------------------------------------------------------------
access(all)
fun test_multi_asset_liquidation_collateral_selection() {
    safeReset()
    
    // STEP 1: Setup liquidity providers
    let moetLp = Test.createAccount()
    setupMoetVault(moetLp, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: moetLp.address, amount: 50000.0, beFailed: false)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: moetLp, amount: 50000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    
    let usdfLp = Test.createAccount()
    var res = setupGenericVault(usdfLp, vaultIdentifier: MAINNET_USDF_TOKEN_ID)
    Test.expect(res, Test.beSucceeded())
    transferFungibleTokens(tokenIdentifier: MAINNET_USDF_TOKEN_ID, from: MAINNET_USDF_HOLDER, to: usdfLp, amount: 10000.0)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: usdfLp, amount: 10000.0, vaultStoragePath: MAINNET_USDF_STORAGE_PATH, pushToDrawDownSink: false)
    
    // STEP 2: Setup user with 3 collateral types
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    res = setupGenericVault(user, vaultIdentifier: MAINNET_USDF_TOKEN_ID)
    Test.expect(res, Test.beSucceeded())
    res = setupGenericVault(user, vaultIdentifier: MAINNET_WETH_TOKEN_ID)
    Test.expect(res, Test.beSucceeded())
    
    let flowAmount: UFix64 = 1000.0
    let usdfAmount: UFix64 = 500.0
    let wethAmount: UFix64 = 0.05
    
    transferFlowTokens(to: user, amount: flowAmount)
    transferFungibleTokens(tokenIdentifier: MAINNET_USDF_TOKEN_ID, from: MAINNET_USDF_HOLDER, to: user, amount: usdfAmount)
    transferFungibleTokens(tokenIdentifier: MAINNET_WETH_TOKEN_ID, from: MAINNET_WETH_HOLDER, to: user, amount: wethAmount)
    
    // STEP 3: Create position with all collateral
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: flowAmount, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
    
    let openEvents = Test.eventsOfType(Type<FlowALPv0.Opened>())
    let pid = (openEvents[openEvents.length - 1] as! FlowALPv0.Opened).pid
    
    depositToPosition(signer: user, positionID: pid, amount: usdfAmount, vaultStoragePath: MAINNET_USDF_STORAGE_PATH, pushToDrawDownSink: false)
    depositToPosition(signer: user, positionID: pid, amount: wethAmount, vaultStoragePath: MAINNET_WETH_STORAGE_PATH, pushToDrawDownSink: false)
    
    // Collateral (effectiveCollateral = balance * price * collateralFactor):
    //   FLOW: 1000 * $1.00 * 0.8 = $800
    //   USDF: 500 * $1.00 * 0.9 = $450
    //   WETH: 0.05 * $2000 * 0.75 = $75
    // Total collateral: $1325
    
    // STEP 4: Create 2 debt types by borrowing
    // First borrow MOET
    // maxBorrow = (effectiveCollateral / minHealth) * borrowFactor / price
    //   MOET: maxBorrow = ($1325 / 1.1) * 1.0 / $1.00 = 1204.54545455 MOET
    borrowFromPosition(signer: user, positionId: pid, tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, amount: 700.0, beFailed: false)
    // Collateral (effectiveCollateral = balance * price * collateralFactor):
    //   FLOW: 1000 * $1.00 * 0.8 = $800
    //   USDF: 500 * $1.00 * 0.9 = $450
    //   WETH: 0.05 * $2000 * 0.75 = $75
    // Total collateral: $1325
    //
    // Debt (effectiveDebt = balance * price / borrowFactor):
    //   MOET: 700 * $1.00 / BF(1.0) = $700
    // Total debt: $700
    //
    // Health = $1325 / $700 = 1.89285714 (healthy)

    // Then borrow USDF
    // First checks: what if we drain all 500 USDF credit
    // Collateral (effectiveCollateral = balance * price * collateralFactor):
    //   FLOW: 1000 * $1.00 * 0.8 = $800
    //   WETH: 0.05 * $2000 * 0.75 = $75
    // Total collateral: $875
    //
    // Debt (effectiveDebt = balance * price / borrowFactor):
    //   MOET: 700 * $1.00 / BF(1.0) = $700
    // Total debt: $700
    //
    // Health = $875 / $700 = 1.25 (still healthy)

    // USDF: availableDebtToIncrease = ($875 / 1.1) - $700 = $795.454... - $700 = $95.454
    // USDF: maxBorrow = ($95.454... * 0.95 / $1.00) + $500 = 590.68 USDF
    borrowFromPosition(signer: user, positionId: pid, tokenTypeIdentifier: MAINNET_USDF_TOKEN_ID, vaultStoragePath: MAINNET_USDF_STORAGE_PATH, amount: 550.0, beFailed: false)

    // Position now has:
    // Collateral (effectiveCollateral = balance * price * collateralFactor):
    //   FLOW: 1000 * $1.00 * 0.8 = $800 
    //   WETH: 0.05 * $2000 * 0.75 = $75
    // Total collateral: $875
    //
    // Debt (effectiveDebt = balance * price / borrowFactor):
    //   MOET: 700 * $1.00 / BF(1.0) = $700
    //   USDF: 50 * $1.00 / BF(0.95) = $52.63
    // Total debt: $752.63
    //
    // Health = $875 / $752.63 = 1.163 (still healthy, will become unhealthy after price drop)
    
    let healthBefore = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(healthBefore > 1.0, message: "Position should be healthy before price drop")

    // STEP 5: Drop FLOW price from $1.00 to $0.70 to make liquidation more attractive
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_FLOW_TOKEN_ID, price: 0.70)
    // Update DEX price to match oracle
    setMockDexPriceForPair(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        inVaultIdentifier: MAINNET_FLOW_TOKEN_ID,
        outVaultIdentifier: MAINNET_MOET_TOKEN_ID,
        vaultSourceStoragePath: MOET.VaultStoragePath,
        priceRatio: 0.70
    )
    
    // New collateral (effectiveCollateral = balance * price * collateralFactor):
    //   FLOW: 1000 * $0.7 * 0.8 = $560
    //   WETH: 0.05 * $2000 * 0.75 = $75
    // Total collateral: $635
    //
    // Debt (effectiveDebt = balance * price / borrowFactor):
    //   MOET: 700 * $1.00 / 1.0 = $700, 
    //   USDF: 50 * $1.00 / 0.95 = $52.63
    // Total debt: $752.63
    //
    // Health = $635 / $752.63 = 0.843706293706293706293706 (unhealthy)

    let healthAfterDrop = getPositionHealth(pid: pid, beFailed: false)
    let expectedHealthAfterDrop: UFix128 = 0.843706293706293706293706
    Test.assertEqual(expectedHealthAfterDrop, healthAfterDrop)
    
    // STEP 6: Liquidator chooses to seize FLOW collateral by repaying MOET debt
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: liquidator.address, amount: 1000.0, beFailed: false)
    
    // Repay 100 MOET, seize FLOW
    // DEX quote: 100 / 0.70 = 142.86 FLOW
    // Liquidator offers: 140 FLOW (better price)
    let repayAmount: UFix64 = 100.0
    let seizeAmount: UFix64 = 140.0

    let liqRes = manualLiquidation(
        signer:liquidator, 
        pid: pid, 
        debtVaultIdentifier: MAINNET_MOET_TOKEN_ID, 
        seizeVaultIdentifier: MAINNET_FLOW_TOKEN_ID, 
        seizeAmount: seizeAmount, 
        repayAmount: repayAmount, 
    )
    Test.expect(liqRes, Test.beSucceeded())

    
    // Verify balances after liquidation
    let details = getPositionDetails(pid: pid, beFailed: false)
    let flowCredit = getCreditBalanceForType(details: details, vaultType: Type<@FlowToken.Vault>())
    let expectedFlowCredit: UFix64 = 860.0 // 1000 - 140
    Test.assertEqual(expectedFlowCredit, flowCredit) 
    
    let moetDebit = getDebitBalanceForType(details: details, vaultType: Type<@MOET.Vault>())
    let expectedMoetDebit: UFix64 = 600.0 // 700 - 100
    Test.assertEqual(expectedMoetDebit, moetDebit)
}

// -----------------------------------------------------------------------------
// Test: Multi-Asset Complex Workflow
// Complete lifecycle demonstrating:
// 1. Multi-collateral deposits (FLOW, USDF)
// 2. Borrowing against collateral (MOET)
// 3. Price shock (FLOW drops 20%)
// 4. Auto-rebalance with topUpSource (pulls WETH)
// 5. Health restoration to target
// -----------------------------------------------------------------------------
access(all)
fun test_multi_asset_complex_workflow() {
    safeReset()
    
    // STEP 1: Setup liquidity providers
    let moetLp = Test.createAccount()
    setupMoetVault(moetLp, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: moetLp.address, amount: 50000.0, beFailed: false)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: moetLp, amount: 50000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    
    // STEP 2: User deposits FLOW collateral
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    var res = setupGenericVault(user, vaultIdentifier: MAINNET_USDF_TOKEN_ID)
    Test.expect(res, Test.beSucceeded())
    res = setupGenericVault(user, vaultIdentifier: MAINNET_WETH_TOKEN_ID)
    Test.expect(res, Test.beSucceeded())
    
    transferFlowTokens(to: user, amount: 1000.0)
    
    // STEP 3: Create position with FLOW
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: user, amount: 1000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
    
    let openEvents = Test.eventsOfType(Type<FlowALPv0.Opened>())
    let pid = (openEvents[openEvents.length - 1] as! FlowALPv0.Opened).pid
    
    // Collateral(effectiveCollateral = balance * price * collateralFactor): 
    //  FLOW: 1000 * $1.00 * 0.8 = $800
    // Total collateral: $800
    
    // STEP 4: User deposits USDF collateral
    transferFungibleTokens(tokenIdentifier: MAINNET_USDF_TOKEN_ID, from: MAINNET_USDF_HOLDER, to: user, amount: 500.0)
    depositToPosition(signer: user, positionID: pid, amount: 500.0, vaultStoragePath: MAINNET_USDF_STORAGE_PATH, pushToDrawDownSink: false)
    
    // Collateral (effectiveCollateral = balance * price * collateralFactor): 
    //   FLOW: 1000 * $1.00 * 0.8 = $800
    //   USDF: 500 * $1.00 * 0.9 = $450
    // Total collateral: $800 + $450 = $1250
    // 
    // Debt: 0
    // 
    // Health: ∞ (no debt)
    
    let healthAfterDeposits = getPositionHealth(pid: pid, beFailed: false)
    
    // STEP 5: User borrows MOET
    borrowFromPosition(signer: user, positionId: pid, tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MOET.VaultStoragePath, amount: 300.0, beFailed: false)
    
    let healthAfterBorrow = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(healthAfterBorrow > 1.0, message: "Position should be healthy after borrowing")
    
    // STEP 6: FLOW price drops 20% ($1.00 → $0.80)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_FLOW_TOKEN_ID, price: 0.80)
    setMockDexPriceForPair(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        inVaultIdentifier: MAINNET_FLOW_TOKEN_ID,
        outVaultIdentifier: MAINNET_MOET_TOKEN_ID,
        vaultSourceStoragePath: MOET.VaultStoragePath,
        priceRatio: 0.80
    )
    
    // New collateral calculation (effectiveCollateral = balance * price * collateralFactor):
    //   FLOW: 1000 * $0.80 * 0.8 = $640 (was $800)
    //   USDF: 500 * $1.00 * 0.9 = $450 (unchanged)
    // Total collateral: $1090 (was $1250)
    //
    // Debt:
    //   MOET: 300 * $1.00 / 1.0 = $300
    // Total debt: $300
    //
    // Health: $1090 / $300 = 3.633 (still healthy but reduced)
    
    let healthAfterDrop = getPositionHealth(pid: pid, beFailed: false)
    
    // STEP 7: User borrows more to approach undercollateralization
    // Max borrow ((effectiveCollateral / minHealth) * borrowFactor / price):
    // Max MOET borrow = ($1090 / 1.1) * 1.0 / $1.0 = ~990.9090 MOET
    borrowFromPosition(signer: user, positionId: pid, tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID, vaultStoragePath: MOET.VaultStoragePath, amount: 600.0, beFailed: false)
    
    // Collateral (effectiveCollateral = balance * price * collateralFactor):
    //   FLOW: 1000 * $0.80 * 0.8 = $640 (was $800)
    //   USDF: 500 * $1.00 * 0.9 = $450 (unchanged)
    // Debt:
    //   MOET: (300 + 600) * $1.00 / 1.0 = $900
    //
    // Total debt: $900
    //
    // Health: $1090 / $900 = 1.211111111111111111111111 (close to minimum)
    
    let healthAfterSecondBorrow = getPositionHealth(pid: pid, beFailed: false)
    let expectedHealthAfterSecondBorrow:UFix128 = 1.211111111111111111111111
    Test.assertEqual(expectedHealthAfterSecondBorrow, healthAfterSecondBorrow)
    
    // STEP 8: User deposits WETH as additional collateral    
    // User deposits their WETH (0.05) directly to the position
    transferFungibleTokens(tokenIdentifier: MAINNET_WETH_TOKEN_ID, from: MAINNET_WETH_HOLDER, to: user, amount: 0.05)
    depositToPosition(signer: user, positionID: pid, amount: 0.05, vaultStoragePath: MAINNET_WETH_STORAGE_PATH, pushToDrawDownSink: true)

    // depositToPosition with pushToDrawDownSink=true:
    // 
    // 1. WETH is deposited → collateral increases from $1090 to $1165
    // 2. Health calculation BEFORE rebalance: $1165 / $900 = 1.294444...
    // 3. System checks: Is health > targetHealth (1.3)? NO (1.294 < 1.3)
    // 4. System checks: Is health < minHealth (1.1)? NO (1.294 > 1.1)
    // 5. Since health is BETWEEN minHealth and targetHealth, rebalance DOES trigger (The position is undercollateralized relative to target)
    //
    // Target health = effectiveCollateral / effectiveDebt
    // Target health = 1.3, effectiveCollateral = $1165
    // effectiveDebt = $1165 / 1.3 = $896.15384615...
    // Current debt: $900
    // Excess debt to push out: $900 - $896.15384615 = $3.84615385
    let expectedPushedAmount: UFix64 = 3.84615385

    // Check if rebalance event was emitted
    let rebalanceEvents = Test.eventsOfType(Type<FlowALPv0.Rebalanced>())
    Test.assertEqual(1, rebalanceEvents.length) 
    let lastRebalance = rebalanceEvents[rebalanceEvents.length - 1] as! FlowALPv0.Rebalanced
    Test.assertEqual(pid, lastRebalance.pid)
    Test.assertEqual(expectedPushedAmount, lastRebalance.amount)
    
    // After rebalance, position is at targetHealth (1.3)
    // Updated collateral (effectiveCollateral = balance * price * collateralFactor):
    //   FLOW: 1000 * $0.80 * 0.8 = $640
    //   USDF: 500 * $1.00 * 0.9 = $450
    //   WETH: 0.05 * $2000 * 0.75 = $75
    // Total collateral: $1165
    //
    // Debt after rebalance:
    //   MOET: 900 - 3.84615385 = 896.15384615 MOET
    // Total debt: $896.15384615 / 1.0 = $896.15384615
    //
    // Health: $1165 / $896.15384615 = 1.300000000005579399141654
    let expectedHealthAfterWethDeposit: UFix128 = 1.300000000005579399141654
    let expectedDebtAfterRebalance: UFix64 = 896.15384615
    
    let healthAfterWethDeposit = getPositionHealth(pid: pid, beFailed: false)
    Test.assertEqual(expectedHealthAfterWethDeposit, healthAfterWethDeposit)

    // Verify user MOET in position
    let details = getPositionDetails(pid: pid, beFailed: false)
    let moetDebtAfterRebalance = getDebitBalanceForType(details: details, vaultType: Type<@MOET.Vault>())
    Test.assertEqual(expectedDebtAfterRebalance, moetDebtAfterRebalance)
}