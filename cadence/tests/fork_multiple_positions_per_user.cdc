#test_fork(network: "mainnet", height: 142528994)

import Test
import BlockchainHelpers

import "FlowToken"
import "FungibleToken"
import "MOET"
import "FlowALPv1"
import "test_helpers.cdc"

// Real mainnet token identifiers (overriding test_helpers for mainnet)
access(all) let FLOW_TOKEN_IDENTIFIER_MAINNET = "A.1654653399040a61.FlowToken.Vault"
access(all) let USDC_TOKEN_IDENTIFIER = "A.f1ab99c82dee3526.USDCFlow.Vault"
access(all) let USDF_TOKEN_IDENTIFIER = "A.1e4aa0b87d10b141.EVMVMBridgedToken_2aabea2058b5ac2d339b163c6ab6f2b6d53aabed.Vault"
access(all) let WETH_TOKEN_IDENTIFIER = "A.1e4aa0b87d10b141.EVMVMBridgedToken_2f6f07cdcf3588944bf4c42ac74ff24bf56e7590.Vault"
access(all) let WBTC_TOKEN_IDENTIFIER = "A.1e4aa0b87d10b141.EVMVMBridgedToken_717dae2baf7656be9a9b01dee31d571a9d4c9579.Vault"
access(all) let MOET_TOKEN_IDENTIFIER_MAINNET = "A.6b00ff876c299c61.MOET.Vault"

// Storage paths for different token types
access(all) let USDC_VAULT_STORAGE_PATH = /storage/usdcFlowVault
access(all) let USDF_VAULT_STORAGE_PATH = /storage/EVMVMBridgedToken_2aabea2058b5ac2d339b163c6ab6f2b6d53aabedVault
access(all) let WETH_VAULT_STORAGE_PATH = /storage/EVMVMBridgedToken_2f6f07cdcf3588944bf4c42ac74ff24bf56e7590Vault
access(all) let WBTC_VAULT_STORAGE_PATH = /storage/EVMVMBridgedToken_717dae2baf7656be9a9b01dee31d571a9d4c9579Vault

// Protocol account: in fork mode, Test.deployContract() deploys to the contract's mainnet
// alias address. FlowALPv1's mainnet alias is 0x47f544294e3b7656, so PoolFactory and all
// pool admin resources are stored there. Note: this is the same address as wbtcHolder.
access(all) let protocolAccount = Test.getAccount(0x47f544294e3b7656)

access(all) let usdfHolder = Test.getAccount(0xf18b50870aed46ad) // 25000
access(all) let wethHolder = Test.getAccount(0xf62e3381a164f993) // 0.07032
access(all) let wbtcHolder = Test.getAccount(0x47f544294e3b7656) // 0.0005
access(all) let flowHolder = Test.getAccount(0xe467b9dd11fa00df) // 1921
access(all) let usdcHolder = Test.getAccount(0xec6119051f7adc31) // 97

access(all) var snapshot: UInt64 = 0

access(all)
fun safeReset() {
    let cur = getCurrentBlockHeight()
    if cur > snapshot {
        Test.reset(to: snapshot)
    }
}

access(all) fun setup() {

    // Deploy DeFiActionsUtils
    var err = Test.deployContract(
        name: "DeFiActionsUtils",
        path: "../../FlowActions/cadence/contracts/utils/DeFiActionsUtils.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    // Deploy FlowALPMath
    err = Test.deployContract(
        name: "FlowALPMath",
        path: "../lib/FlowALPMath.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    // Deploy DeFiActions
    err = Test.deployContract(
        name: "DeFiActions",
        path: "../../FlowActions/cadence/contracts/interfaces/DeFiActions.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    // Deploy MockOracle (references mainnet MOET)
    err = Test.deployContract(
        name: "MockOracle",
        path: "../contracts/mocks/MockOracle.cdc",
        arguments: [MOET_TOKEN_IDENTIFIER_MAINNET]
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

    // Deploy FlowALPv1
    err = Test.deployContract(
        name: "FlowALPv1",
        path: "../contracts/FlowALPv1.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER_MAINNET, beFailed: false)

    // Setup pool with real mainnet token prices
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER_MAINNET, price: 1.0)
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: USDC_TOKEN_IDENTIFIER, price: 1.0)
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: USDF_TOKEN_IDENTIFIER, price: 1.0)
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: WETH_TOKEN_IDENTIFIER, price: 3500.0)
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: WBTC_TOKEN_IDENTIFIER, price: 50000.0)
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: MOET_TOKEN_IDENTIFIER_MAINNET, price: 1.0)

    // Add multiple token types as supported collateral (FLOW, USDC, USDF, WETH, WBTC)
    addSupportedTokenZeroRateCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER_MAINNET,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    addSupportedTokenZeroRateCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: USDC_TOKEN_IDENTIFIER,
        collateralFactor: 0.85,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    addSupportedTokenZeroRateCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: USDF_TOKEN_IDENTIFIER,
        collateralFactor: 0.85,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    addSupportedTokenZeroRateCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: WETH_TOKEN_IDENTIFIER,
        collateralFactor: 0.75,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // Set minimum deposit for WETH to 0.01 (since holder only has 0.07032)
    setMinimumTokenBalancePerPosition(signer: protocolAccount, tokenTypeIdentifier: WETH_TOKEN_IDENTIFIER, minimum: 0.01)

    addSupportedTokenZeroRateCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: WBTC_TOKEN_IDENTIFIER,
        collateralFactor: 0.75,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )
    // Set minimum deposit for WBTC to 0.0001 (since holder only has 0.0005)
    setMinimumTokenBalancePerPosition(signer: protocolAccount, tokenTypeIdentifier: WBTC_TOKEN_IDENTIFIER, minimum: 0.0001)

    snapshot = getCurrentBlockHeight()
}

/// Transfer tokens from holder to recipient (creates vault for recipient if needed)
access(all) fun transferTokensFromHolder(holder: Test.TestAccount, recipient: Test.TestAccount, amount: UFix64, storagePath: StoragePath, tokenName: String) {
    let tx = Test.Transaction(
        code: Test.readFile("../transactions/test/transfer_tokens_with_setup.cdc"),
        authorizers: [holder.address, recipient.address],
        signers: [holder, recipient],
        arguments: [amount, storagePath]
    )
    let result = Test.executeTransaction(tx)
    Test.expect(result, Test.beSucceeded())
}

/// Test Multiple Positions Per User
///
/// Validates requirements:
/// 1. User creates 5+ positions with different collateral types
/// 2. Each position has different health factors
/// 3. Operations on one position should not affect others (isolation)
///
access(all) fun testMultiplePositionsPerUser() {
    safeReset()

    log("Testing Multiple Positions with Real Mainnet Tokens\n")

    let lpUser = Test.createAccount()
    let user = Test.createAccount()

    // Transfer FLOW from holder to LP
    log("Setting up liquidity provider with FLOW\n")
    let liquidityAmount = 800.0
    transferTokensFromHolder(holder: flowHolder, recipient: lpUser, amount: liquidityAmount, storagePath: FLOW_VAULT_STORAGE_PATH, tokenName: "FLOW")

    // LP deposits FLOW to create liquidity for borrowing
    createPosition(admin: protocolAccount, signer: lpUser, amount: liquidityAmount, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    //////////// Position creation ///////////////////
    log("Create 5 Positions with Different Collateral Types\n")

    // Define positions with different collateral types
    // Token holder balances and prices:
    // - flowHolder: 1921 FLOW x $1 = $1921
    // - usdfHolder: 25000 USDF x $1 = $25000
    // - usdcHolder: 97 USDC x $1 = $97
    // - wethHolder: 0.07032 WETH x $3500 = $246.12
    // - wbtcHolder: 0.0005 WBTC x $50000 = $25

    let positions = [
        {"type": FLOW_TOKEN_IDENTIFIER_MAINNET, "amount": 500.0, "storagePath": FLOW_VAULT_STORAGE_PATH, "name": "FLOW", "holder": flowHolder},
        {"type": USDF_TOKEN_IDENTIFIER, "amount": 1500.0, "storagePath": USDF_VAULT_STORAGE_PATH, "name": "USDF", "holder": usdfHolder},
        {"type": USDC_TOKEN_IDENTIFIER, "amount": 10.0, "storagePath": USDC_VAULT_STORAGE_PATH, "name": "USDC", "holder": usdcHolder},
        {"type": WETH_TOKEN_IDENTIFIER, "amount": 0.05, "storagePath": WETH_VAULT_STORAGE_PATH, "name": "WETH", "holder": wethHolder},
        {"type": WBTC_TOKEN_IDENTIFIER, "amount": 0.0004, "storagePath": WBTC_VAULT_STORAGE_PATH, "name": "WBTC", "holder": wbtcHolder}
    ]

    let debts = [100.0, 150.0, 5.0, 50.0, 8.0]

    var userPids: [UInt64] = []

    for i, position in positions {
        let collateralType = position["type"]! as! String
        let collateralName = position["name"]! as! String
        let collateralAmount = position["amount"]! as! UFix64
        let storagePath = position["storagePath"]! as! StoragePath
        let holder = position["holder"]! as! Test.TestAccount

        // Transfer tokens from holder to user
        transferTokensFromHolder(holder: holder, recipient: user, amount: collateralAmount, storagePath: storagePath, tokenName: collateralName)

        createPosition(admin: protocolAccount, signer: user, amount: collateralAmount, vaultStoragePath: storagePath, pushToDrawDownSink: false)
        let openEvts = Test.eventsOfType(Type<FlowALPv1.Opened>())
        userPids.append((openEvts[openEvts.length - 1] as! FlowALPv1.Opened).pid)

        // Calculate USD value based on token price from oracle
        let price = getOraclePrice(tokenIdentifier: collateralType)
        let value = collateralAmount * price
        log("  Position \(userPids[i]): \(collateralAmount) \(collateralName) collateral (\(value) value)")
    }

    //////////// Borrowing from each position ///////////////////

    log("Borrowing different amounts from each position\n")

    var healths: [UFix128] = []
    for i, debt in debts {
        let pid = userPids[i]
        borrowFromPosition(signer: user, positionId: pid, tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER_MAINNET, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, amount: debt, beFailed: false)

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

    log("\n  Action: Borrow 100 more FLOW from Position \(isolationTestPid)\n")
    borrowFromPosition(signer: user, positionId: isolationTestPid, tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER_MAINNET, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, amount: additionalDebt, beFailed: false)

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

/// Test Position Interactions Through Shared Liquidity Pools
///
/// Validates that multiple positions interact through shared pool resources:
/// 1. Multiple positions compete for limited deposit capacity
/// 2. Position A's borrowing reduces available liquidity for Position B
/// 3. Shared liquidity pools create cross-position effects
/// 4. Pool capacity constraints affect all positions
access(all) fun testPositionInteractionsSharedLiquidity() {
    safeReset()

    log("Testing Position Interactions Through Shared Liquidity Pools\n")

    // Create liquidity provider to deposit FLOW (the shared liquidity pool)
    let lpUser = Test.createAccount()
    let user = Test.createAccount()

    log("Setting up shared liquidity pool with limited capacity\n")
    let liquidityAmount = 400.0
    transferTokensFromHolder(holder: flowHolder, recipient: lpUser, amount: liquidityAmount, storagePath: FLOW_VAULT_STORAGE_PATH, tokenName: "FLOW")

    // LP deposits FLOW - this creates the shared liquidity pool
    createPosition(admin: protocolAccount, signer: lpUser, amount: liquidityAmount, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
    log("  Liquidity Provider deposited: \(liquidityAmount) FLOW\n")

    //////////// Create Position A with USDC collateral ///////////////////

    let userACollateral = 90.0  // 90 USDC
    log("Creating Position A with \(userACollateral) USDC collateral\n")
    transferTokensFromHolder(holder: usdcHolder, recipient: user, amount: userACollateral, storagePath: USDC_VAULT_STORAGE_PATH, tokenName: "USDC")
    createPosition(admin: protocolAccount, signer: user, amount: userACollateral, vaultStoragePath: USDC_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
    var openEvts = Test.eventsOfType(Type<FlowALPv1.Opened>())
    let positionA_id = (openEvts[openEvts.length - 1] as! FlowALPv1.Opened).pid

    //////////// Create Position B with USDF collateral ///////////////////

    let userBCollateral = 500.0  // 500 USDF
    log("Creating Position B with \(userBCollateral) USDF collateral\n")
    transferTokensFromHolder(holder: usdfHolder, recipient: user, amount: userBCollateral, storagePath: USDF_VAULT_STORAGE_PATH, tokenName: "USDF")
    createPosition(admin: protocolAccount, signer: user, amount: userBCollateral, vaultStoragePath: USDF_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
    openEvts = Test.eventsOfType(Type<FlowALPv1.Opened>())
    let positionB_id = (openEvts[openEvts.length - 1] as! FlowALPv1.Opened).pid

    //////////// 1. Position A borrows heavily, affecting available liquidity ///////////////////

    log("Position A borrows heavily from shared pool\n")
    // Formula: Effective Collateral = (debitAmount * price) * collateralFactor = (90 × 1.0) × 0.85 = 76.50
    // Max Borrow = 76.50 / 1.1 (minHealth) = 69.55 FLOW
    // Health after borrow = 76.50 / 60 = 1.275
    let positionA_borrow1 = 60.0  // Borrow 60 FLOW (within max 69.55)
    borrowFromPosition(signer: user, positionId: positionA_id, tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER_MAINNET, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, amount: positionA_borrow1, beFailed: false)

    let healthA_after1 = getPositionHealth(pid: positionA_id, beFailed: false)
    log("  Position A borrowed \(positionA_borrow1) FLOW - Health: \(healthA_after1)\n")

    // Check remaining liquidity in pool
    let remainingLiquidity1 = 340.0 // liquidityAmount - positionA_borrow1 = 400.0 - 60.0 = 340.0
    log("  Remaining liquidity in pool: \(remainingLiquidity1) FLOW\n")

    //////////// 2. Position B borrows successfully from shared pool ///////////////////
    log("Position B borrows from shared pool\n")

    // Formula: Effective Collateral = (debitAmount * price) * collateralFactor = (500 × 1.0) × 0.85 = 425.00
    // Max Borrow = 425.00 / 1.1 (minHealth) = 386.36 FLOW
    let positionB_borrow1 = 340.0  // Borrow 340 FLOW (within max 386.36 borrow and 340 remaining liquidity)
    log("  Attempting to borrow \(positionB_borrow1) FLOW...")
    borrowFromPosition(signer: user, positionId: positionB_id, tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER_MAINNET, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, amount: positionB_borrow1, beFailed: false)
    log("  Success - Position B borrowed \(positionB_borrow1) FLOW")
    let healthB_after1 = getPositionHealth(pid: positionB_id, beFailed: false)
    log("  Position B Health: \(healthB_after1)\n")

    let remainingLiquidity2 = 0.0
    log("  Remaining liquidity in pool: \(remainingLiquidity2) FLOW\n")

    //////////// 3. Position B tries to exceed max borrowing capacity - expects failure ///////////////////
    log("Position B tries to borrow beyond its capacity - EXPECTS FAILURE\n")

    // Position B can't borrow more because remaining liquidity is 0
    let positionB_borrow2_attempt = 1.0
    log("  Attempting to borrow \(positionB_borrow2_attempt) FLOW...")
    borrowFromPosition(signer: user, positionId: positionB_id, tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER_MAINNET, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, amount: positionB_borrow2_attempt, beFailed: true)
    log("  Failed as expected - remaining liquidity is 0\n")

    let healthB_after2 = getPositionHealth(pid: positionB_id, beFailed: false)

    //////////// 4. Position A repayment increases available liquidity ///////////////////
    log("Position A repays debt, freeing liquidity back to pool\n")

    // Position A repays substantial debt by depositing borrowed FLOW back
    let repayAmount = 40.0

    // Deposit FLOW back to position (repays debt using previously borrowed funds)
    depositToPosition(signer: user, positionID: positionA_id, amount: repayAmount, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    let healthA_after2 = getPositionHealth(pid: positionA_id, beFailed: false)
    log("  Position A repaid \(repayAmount) FLOW - Health: \(healthA_after2)\n")

    let remainingLiquidity4 = repayAmount // 40.0, because remainingLiquidity2 == 0
    log("  Remaining liquidity in pool after repayment: \(remainingLiquidity4) FLOW\n")

    //////////// Verify cross-position effects ///////////////////

    Test.assert(healthA_after2 > healthA_after1, message: "Position A health should improve after repayment")
    Test.assert(healthB_after2 == healthB_after1, message: "Position B health should be unchanged - second borrow attempt failed")


    //////////// 5. Test Position A health change affects Position B's borrowing capacity ///////////////////
    log("Testing how Position A's health deterioration affects Position B\n")

    let healthB_before_priceChange = getPositionHealth(pid: positionB_id, beFailed: false)
    log("  Position B health: \(healthB_before_priceChange)")

    // Crash USDC price (Position A's collateral) from $1.0 to $0.5
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: USDC_TOKEN_IDENTIFIER, price: 0.5)

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
    let positionB_borrow3 = 30.0  // Well within remaining capacity (40 FLOW available, 46.36 max allowed)
    log("  Position B attempts to borrow \(positionB_borrow3) FLOW after Position A's health deterioration...")
    borrowFromPosition(signer: user, positionId: positionB_id, tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER_MAINNET, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, amount: positionB_borrow3, beFailed: false)
    log("  Success - Position B can still borrow despite Position A's poor health\n")

    let healthB_final = getPositionHealth(pid: positionB_id, beFailed: false)
    log("  Position B final health: \(healthB_final)\n")
    Test.assert(healthB_final < healthB_after_priceChange, message: "Position B health decreases from its own borrowing, not Position A's health")

}

/// Test Batch Liquidations
///
/// Validates batch liquidation capabilities:
/// 1. Multiple unhealthy positions liquidated in SINGLE transaction
/// 2. Partial liquidation of multiple positions
/// 3. Gas cost optimization through batch processing
access(all) fun testBatchLiquidations() {
    safeReset()

    log("Testing Batch Liquidations of Multiple Positions\n")

    let lpUser = Test.createAccount()
    let user = Test.createAccount()

    // LP deposits 600 FLOW to provide borrowing liquidity
    // (total borrows = 200+90+40+10+80 = 420 FLOW < 600)
    transferTokensFromHolder(holder: flowHolder, recipient: lpUser, amount: 600.0, storagePath: FLOW_VAULT_STORAGE_PATH, tokenName: "FLOW")
    createPosition(admin: protocolAccount, signer: lpUser, amount: 600.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    // 5 positions with distinct collateral types:
    //
    //  pid | Collateral | Amount      | Borrow   | Crash price | Health after | Action
    //  ----|-----------|-------------|----------|-------------|--------------|--------
    //   1  | USDF      | 500 USDF    | 200 FLOW | $0.30 (-70%)| 0.638        | FULL liquidation
    //   2  | WETH      | 0.06 WETH   |  90 FLOW | $1050 (-70%)| 0.525        | FULL liquidation
    //   3  | USDC      | 80 USDC     |  40 FLOW | $0.50 (-50%)| 0.850        | PARTIAL liquidation
    //   4  | WBTC      | 0.0004 WBTC |  10 FLOW | $25000(-50%)| 0.750        | PARTIAL liquidation
    //   5  | FLOW      | 200 FLOW    |  80 FLOW | $1.00 (0%)  | 2.000        | NOT liquidated
    //
    // FLOW position (pid=5): health = 0.8 * collateral / debt is price-independent
    // when both collateral and debt are FLOW, so any FLOW price crash leaves it unaffected.
    log("Creating 5 positions with different collateral types\n")

    let positions = [
        {"type": USDF_TOKEN_IDENTIFIER,        "amount": 500.0,   "storagePath": USDF_VAULT_STORAGE_PATH, "name": "USDF", "holder": usdfHolder, "borrow": 200.0},
        {"type": WETH_TOKEN_IDENTIFIER,         "amount": 0.06,    "storagePath": WETH_VAULT_STORAGE_PATH, "name": "WETH", "holder": wethHolder, "borrow": 90.0},
        {"type": USDC_TOKEN_IDENTIFIER,         "amount": 80.0,    "storagePath": USDC_VAULT_STORAGE_PATH, "name": "USDC", "holder": usdcHolder, "borrow": 40.0},
        {"type": WBTC_TOKEN_IDENTIFIER,         "amount": 0.0004,  "storagePath": WBTC_VAULT_STORAGE_PATH, "name": "WBTC", "holder": wbtcHolder, "borrow": 10.0},
        {"type": FLOW_TOKEN_IDENTIFIER_MAINNET, "amount": 200.0,   "storagePath": FLOW_VAULT_STORAGE_PATH, "name": "FLOW", "holder": flowHolder, "borrow": 80.0}
    ]

    var userPids: [UInt64] = []

    for i, position in positions {
        let collateralName = position["name"]! as! String
        let collateralAmount = position["amount"]! as! UFix64
        let storagePath = position["storagePath"]! as! StoragePath
        let holder = position["holder"]! as! Test.TestAccount

        transferTokensFromHolder(holder: holder, recipient: user, amount: collateralAmount, storagePath: storagePath, tokenName: collateralName)
        createPosition(admin: protocolAccount, signer: user, amount: collateralAmount, vaultStoragePath: storagePath, pushToDrawDownSink: false)
        let openEvts = Test.eventsOfType(Type<FlowALPv1.Opened>())
        userPids.append((openEvts[openEvts.length - 1] as! FlowALPv1.Opened).pid)
    }

    log("Borrowing FLOW from each position\n")
    var healths: [UFix128] = []
    for i, position in positions {
        let pid = userPids[i]
        let borrowAmount = position["borrow"]! as! UFix64
        let collateralName = position["name"]! as! String

        borrowFromPosition(signer: user, positionId: pid, tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER_MAINNET, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, amount: borrowAmount, beFailed: false)

        let health = getPositionHealth(pid: pid, beFailed: false)
        healths.append(health)
        log("  Position \(pid) (\(collateralName)): Borrowed \(borrowAmount) FLOW - Health: \(health)")
    }

    // Crash collateral prices. FLOW stays at $1.0 so userPids[4] stays healthy.
    log("\nCrashing collateral prices to trigger liquidations\n")
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: USDF_TOKEN_IDENTIFIER, price: 0.3)     // -70%
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: WETH_TOKEN_IDENTIFIER, price: 1050.0)  // -70%
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: USDC_TOKEN_IDENTIFIER, price: 0.5)     // -50%
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: WBTC_TOKEN_IDENTIFIER, price: 25000.0) // -50%

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

    // Setup protocol account FLOW vault as the DEX output source.
    // priceRatio = Pc_crashed / Pd = post-crash collateral price / FLOW price.
    // This must match the oracle prices exactly to pass the DEX/oracle deviation check.
    transferTokensFromHolder(holder: flowHolder, recipient: protocolAccount, amount: 300.0, storagePath: FLOW_VAULT_STORAGE_PATH, tokenName: "FLOW")

    log("\nSetting up DEX swappers (priceRatio = post-crash Pc / Pd)\n")
    setMockDexPriceForPair(
        signer: protocolAccount,
        inVaultIdentifier: USDF_TOKEN_IDENTIFIER,
        outVaultIdentifier: FLOW_TOKEN_IDENTIFIER_MAINNET,
        vaultSourceStoragePath: FLOW_VAULT_STORAGE_PATH,
        priceRatio: 0.3     // $0.30 USDF / $1.00 FLOW
    )
    setMockDexPriceForPair(
        signer: protocolAccount,
        inVaultIdentifier: WETH_TOKEN_IDENTIFIER,
        outVaultIdentifier: FLOW_TOKEN_IDENTIFIER_MAINNET,
        vaultSourceStoragePath: FLOW_VAULT_STORAGE_PATH,
        priceRatio: 1050.0  // $1050 WETH / $1.00 FLOW
    )
    setMockDexPriceForPair(
        signer: protocolAccount,
        inVaultIdentifier: USDC_TOKEN_IDENTIFIER,
        outVaultIdentifier: FLOW_TOKEN_IDENTIFIER_MAINNET,
        vaultSourceStoragePath: FLOW_VAULT_STORAGE_PATH,
        priceRatio: 0.5     // $0.50 USDC / $1.00 FLOW
    )
    setMockDexPriceForPair(
        signer: protocolAccount,
        inVaultIdentifier: WBTC_TOKEN_IDENTIFIER,
        outVaultIdentifier: FLOW_TOKEN_IDENTIFIER_MAINNET,
        vaultSourceStoragePath: FLOW_VAULT_STORAGE_PATH,
        priceRatio: 25000.0 // $25000 WBTC / $1.00 FLOW
    )

    // Liquidator setup: transfer FLOW for debt repayment (total needed: 71+113+4+12 = 200 FLOW)
    // and 1 unit of each collateral token to initialize vault storage paths.
    log("\nSetting up liquidator account\n")
    let liquidator = Test.createAccount()
    transferTokensFromHolder(holder: flowHolder,  recipient: liquidator, amount: 250.0,    storagePath: FLOW_VAULT_STORAGE_PATH, tokenName: "FLOW")
    transferTokensFromHolder(holder: usdfHolder,  recipient: liquidator, amount: 1.0,      storagePath: USDF_VAULT_STORAGE_PATH, tokenName: "USDF")
    transferTokensFromHolder(holder: wethHolder,  recipient: liquidator, amount: 0.001,    storagePath: WETH_VAULT_STORAGE_PATH, tokenName: "WETH")
    transferTokensFromHolder(holder: usdcHolder,  recipient: liquidator, amount: 1.0,      storagePath: USDC_VAULT_STORAGE_PATH, tokenName: "USDC")
    transferTokensFromHolder(holder: wbtcHolder,  recipient: liquidator, amount: 0.00001,  storagePath: WBTC_VAULT_STORAGE_PATH, tokenName: "WBTC")

    // Batch liquidation parameters — ordered worst health first:
    //   WETH (0.525) → USDF (0.638) → WBTC (0.750) → USDC (0.850)
    //
    // seize/repay values satisfy three constraints:
    //   1. seize < quote.inAmount         (offer beats DEX price)
    //   2. postHealth <= 1.05             (liquidationTargetHF default)
    //   3. postHealth > pre-liq health    (position improves)
    //
    // Full liquidations — bring health up to ~1.03-1.04 (as close to 1.05 target as possible):
    //   pid=WETH: repay 71 FLOW, seize 0.035 WETH
    //     postHealth = (47.25 - 0.035*787.5) / (90 - 71) = 19.6875/19 ≈ 1.036
    //     DEX check:  0.035 < 71/1050 = 0.0676
    //   pid=USDF: repay 113 FLOW, seize 147 USDF
    //     postHealth = (127.5 - 147*0.255) / (200 - 113) = 90.015/87 ≈ 1.034
    //     DEX check:  147 < 113/0.3 = 376.7
    //
    // Partial liquidations — improve health without reaching 1.05:
    //   pid=WBTC: repay 4 FLOW, seize 0.00011 WBTC
    //     postHealth = (7.5 - 0.00011*18750) / (10 - 4) = 5.4375/6 ≈ 0.906
    //     DEX check:  0.00011 < 4/25000 = 0.00016
    //   pid=USDC: repay 12 FLOW, seize 17 USDC
    //     postHealth = (34 - 17*0.425) / (40 - 12) = 26.775/28 ≈ 0.956
    //     DEX check:  17 < 12/0.5 = 24

    log("\nExecuting batch liquidation of 4 positions (2 full, 2 partial) in SINGLE transaction...\n")
    // Ordered worst health first: WETH (idx=1), USDF (idx=0), WBTC (idx=3), USDC (idx=2)
    let batchPids = [userPids[1],              userPids[0],             userPids[3],             userPids[2]             ]
    let batchSeizeTypes             = [WETH_TOKEN_IDENTIFIER,    USDF_TOKEN_IDENTIFIER,   WBTC_TOKEN_IDENTIFIER,   USDC_TOKEN_IDENTIFIER   ]
    let batchSeizeAmounts           = [0.035,                    147.0,                   0.00011,                 17.0                    ]
    let batchRepayAmounts           = [71.0,                     113.0,                   4.0,                     12.0                    ]

    let batchLiqRes = _executeTransaction(
        "../transactions/flow-alp/pool-management/batch_manual_liquidation.cdc",
        [batchPids, FLOW_TOKEN_IDENTIFIER_MAINNET, batchSeizeTypes, batchSeizeAmounts, batchRepayAmounts],
        liquidator
    )
    Test.expect(batchLiqRes, Test.beSucceeded())

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
