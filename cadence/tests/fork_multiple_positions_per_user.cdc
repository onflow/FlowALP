#test_fork(network: "mainnet", height: 142528994)

import Test
import BlockchainHelpers

import "FlowToken"
import "FungibleToken"
import "MOET"
import "FlowALPv0"
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
// alias address. FlowALPv0's mainnet alias is 0x47f544294e3b7656, so PoolFactory and all
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

    // Deploy FlowALPv0
    err = Test.deployContract(
        name: "FlowALPv0",
        path: "../contracts/FlowALPv0.cdc",
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
    // Set minimum deposit for WBTC to 0.00001 (since holder only has 0.0005)
    setMinimumTokenBalancePerPosition(signer: protocolAccount, tokenTypeIdentifier: WBTC_TOKEN_IDENTIFIER, minimum: 0.00001)

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

/// Batch-liquidate positions using the liquidator's own tokens as repayment (no DEX).
/// The liquidator must hold sufficient debt tokens upfront.
access(all) fun batchManualLiquidation(
    pids: [UInt64],
    debtVaultIdentifier: String,
    seizeVaultIdentifiers: [String],
    seizeAmounts: [UFix64],
    repayAmounts: [UFix64],
    signer: Test.TestAccount
) {
    let res = _executeTransaction(
        "../transactions/flow-alp/pool-management/batch_manual_liquidation.cdc",
        [pids, debtVaultIdentifier, seizeVaultIdentifiers, seizeAmounts, repayAmounts],
        signer
    )
    Test.expect(res, Test.beSucceeded())
}

/// Batch-liquidate positions using MockDexSwapper as the repayment source in chunks of
/// chunkSize to stay within the computation limit.
access(all) fun batchLiquidateViaMockDex(
    pids: [UInt64],
    debtVaultIdentifier: String,
    seizeVaultIdentifiers: [String],
    seizeAmounts: [UFix64],
    repayAmounts: [UFix64],
    chunkSize: Int,
    signer: Test.TestAccount
) {
    let total = pids.length
    let numChunks = (total + chunkSize - 1) / chunkSize
    for i in InclusiveRange(0, numChunks - 1) {
        let startIdx = i * chunkSize
        var endIdx = startIdx + chunkSize
        if endIdx > total {
            endIdx = total
        }
        let res = _executeTransaction(
            "../transactions/flow-alp/pool-management/batch_liquidate_via_mock_dex.cdc",
            [pids.slice(from: startIdx, upTo: endIdx),
                debtVaultIdentifier,
                seizeVaultIdentifiers.slice(from: startIdx, upTo: endIdx),
                seizeAmounts.slice(from: startIdx, upTo: endIdx),
                repayAmounts.slice(from: startIdx, upTo: endIdx)],
            signer
        )
        Test.expect(res, Test.beSucceeded())
    }
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
        let openEvts = Test.eventsOfType(Type<FlowALPv0.Opened>())
        userPids.append((openEvts[openEvts.length - 1] as! FlowALPv0.Opened).pid)

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
    var openEvts = Test.eventsOfType(Type<FlowALPv0.Opened>())
    let positionA_id = (openEvts[openEvts.length - 1] as! FlowALPv0.Opened).pid

    //////////// Create Position B with USDF collateral ///////////////////

    let userBCollateral = 500.0  // 500 USDF
    log("Creating Position B with \(userBCollateral) USDF collateral\n")
    transferTokensFromHolder(holder: usdfHolder, recipient: user, amount: userBCollateral, storagePath: USDF_VAULT_STORAGE_PATH, tokenName: "USDF")
    createPosition(admin: protocolAccount, signer: user, amount: userBCollateral, vaultStoragePath: USDF_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
    openEvts = Test.eventsOfType(Type<FlowALPv0.Opened>())
    let positionB_id = (openEvts[openEvts.length - 1] as! FlowALPv0.Opened).pid

    //////////// 1. Position A borrows heavily, affecting available liquidity ///////////////////

    log("Position A borrows heavily from shared pool\n")
    // Formula: Effective Collateral = (debitAmount * price) * collateralFactor = (90 × 1.0) × 0.85 = 76.50
    // Max Borrow = 76.50 / 1.1 (minHealth) = 69.55 FLOW
    // Health after borrow = 76.50 / 60 = 1.275
    let positionA_borrow1 = 60.0  // Borrow 60 FLOW (within max 69.55)
    borrowFromPosition(signer: user, positionId: positionA_id, tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER_MAINNET, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, amount: positionA_borrow1, beFailed: false)

    let healthA_after1 = getPositionHealth(pid: positionA_id, beFailed: false)
    log("  Position A borrowed \(positionA_borrow1) FLOW - Health: \(healthA_after1)\n")

    // Check remaining liquidity in pool: liquidityAmount - positionA_borrow1 = 400.0 - 60.0 = 340.0 FLOW
    log("  Remaining liquidity in pool: 340.0 FLOW\n")

    //////////// 2. Position B borrows successfully from shared pool ///////////////////
    log("Position B borrows from shared pool\n")

    // Formula: Effective Collateral = (collateralAmount * price) * collateralFactor = (500 × 1.0) × 0.85 = 425.00
    // Max Borrow = 425.00 / 1.1 (minHealth) = 386.36 FLOW
    let positionB_borrow1 = 340.0  // Borrow 340 FLOW (within max 386.36 borrow and 340 remaining liquidity)
    log("  Attempting to borrow \(positionB_borrow1) FLOW...")
    borrowFromPosition(signer: user, positionId: positionB_id, tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER_MAINNET, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, amount: positionB_borrow1, beFailed: false)
    log("  Success - Position B borrowed \(positionB_borrow1) FLOW")
    let healthB_after1 = getPositionHealth(pid: positionB_id, beFailed: false)
    log("  Position B Health: \(healthB_after1)\n")
    log("  Remaining liquidity in pool: 0.0 FLOW\n")

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
    log("  Remaining liquidity in pool after repayment: \(repayAmount) FLOW\n")

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
    //  pid | Collateral| Amount      | Borrow   | Crash price | Health after | Action
    //  ----|-----------|-------------|----------|-------------|--------------|--------
    //   1  | USDF      | 500 USDF    | 200 FLOW | $0.30 (-70%)| 0.638        | FULL liquidation
    //   2  | WETH      | 0.06 WETH   |  90 FLOW | $1050 (-70%)| 0.525        | FULL liquidation
    //   3  | USDC      | 80 USDC     |  40 FLOW | $0.50 (-50%)| 0.850        | PARTIAL liquidation
    //   4  | WBTC      | 0.0004 WBTC |  10 FLOW | $25000(-50%)| 0.750        | PARTIAL liquidation
    //   5  | FLOW      | 200 FLOW    |  80 FLOW | $1.00 (0%)  | 2.000        | NOT liquidated
    //
    log("Creating 5 positions with different collateral types\n")

    let positions = [
        {"type": USDF_TOKEN_IDENTIFIER,         "amount": 500.0,   "storagePath": USDF_VAULT_STORAGE_PATH, "name": "USDF", "holder": usdfHolder, "borrow": 200.0},
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
        let openEvts = Test.eventsOfType(Type<FlowALPv0.Opened>())
        userPids.append((openEvts[openEvts.length - 1] as! FlowALPv0.Opened).pid)
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
    //
    // Repay amounts derived from: repay = debt - (collat - seize) * CF * P_crashed / H_target
    //   WETH=71:  debt=90,  (0.06-0.035)*0.75*1050 = 19.6875, H≈1.034 → 90  - 19.6875/1.034 ≈ 71
    //   USDF=113: debt=200, (500-147)*0.85*0.3      = 90.015,  H≈1.034 → 200 - 90.015/1.034  ≈ 113
    //   WBTC=4:   partial;  (0.0004-0.00011)*0.75*25000 = 5.4375 → repay=4  → postHealth=5.4375/6≈0.906
    //   USDC=12:  partial;  (80-17)*0.85*0.5            = 26.775 → repay=12 → postHealth=26.775/28≈0.956
    log("\nSetting up liquidator account\n")
    let liquidator = Test.createAccount()
    transferTokensFromHolder(holder: flowHolder, recipient: liquidator, amount: 250.0,   storagePath: FLOW_VAULT_STORAGE_PATH, tokenName: "FLOW")
    transferTokensFromHolder(holder: usdfHolder, recipient: liquidator, amount: 1.0,     storagePath: USDF_VAULT_STORAGE_PATH, tokenName: "USDF")
    transferTokensFromHolder(holder: wethHolder, recipient: liquidator, amount: 0.001,   storagePath: WETH_VAULT_STORAGE_PATH, tokenName: "WETH")
    transferTokensFromHolder(holder: usdcHolder, recipient: liquidator, amount: 1.0,     storagePath: USDC_VAULT_STORAGE_PATH, tokenName: "USDC")
    transferTokensFromHolder(holder: wbtcHolder, recipient: liquidator, amount: 0.00001, storagePath: WBTC_VAULT_STORAGE_PATH, tokenName: "WBTC")

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
    let batchPids          = [userPids[0],           userPids[1],           userPids[2],           userPids[3]          ]
    let batchSeizeTypes    = [USDF_TOKEN_IDENTIFIER, WETH_TOKEN_IDENTIFIER, USDC_TOKEN_IDENTIFIER, WBTC_TOKEN_IDENTIFIER]
    let batchSeizeAmounts  = [147.0,                 0.035,                 17.0,                  0.00011              ]
    let batchRepayAmounts  = [113.0,                 71.0,                  12.0,                  4.0                  ]

    batchManualLiquidation(
        pids: batchPids,
        debtVaultIdentifier: FLOW_TOKEN_IDENTIFIER_MAINNET,
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

/// Test Mass Simultaneous Unhealthy Positions – 100-Position Multi-Collateral Stress Test
///
/// System-wide stress test validating protocol behavior under mass position failure
/// across three collateral types — all crashing 40% simultaneously:
///
///   100 positions (all borrowing FLOW as debt):
///     Group A: 50 USDF positions (10 USDF each)   — 25 high-risk + 25 moderate
///     Group B: 45 USDC positions (2 USDC each)    — 23 high-risk + 22 moderate
///     Group C:  5 WBTC positions (0.00009 WBTC ea) — 5 uniform (same risk tier)
///
///   Health before crash (CF_USDF=CF_USDC=0.85, CF_WBTC=0.75):
///     USDF high-risk:  borrow 7.0 FLOW  → (10×1.0×0.85)/7.0       = 1.214
///     USDF moderate:   borrow 6.0 FLOW  → (10×1.0×0.85)/6.0       = 1.417
///     USDC high-risk:  borrow 1.4 FLOW  → (2×1.0×0.85)/1.4        = 1.214
///     USDC moderate:   borrow 1.2 FLOW  → (2×1.0×0.85)/1.2        = 1.417
///     WBTC uniform:    borrow 2.5 FLOW  → (0.00009×50000×0.75)/2.5 = 1.350
///
///   All collateral crashes 40% simultaneously:
///     USDF: $1.00 → $0.60  |  USDC: $1.00 → $0.60  |  WBTC: $50000 → $30000
///
///   Health after crash:
///     USDF high:  (10×0.60×0.85)/7.0       = 0.729    USDF mod:  (10×0.60×0.85)/6.0      = 0.850
///     USDC high:  (2×0.60×0.85)/1.4        = 0.729    USDC mod:  (2×0.60×0.85)/1.2       = 0.850
///     WBTC:       (0.00009×30000×0.75)/2.5 = 0.810
///
///   Liquidation (liquidationTargetHF=1.05, post target≈1.02–1.04):
///     USDF high:  seize 4.0 USDF,      repay 4.0 FLOW  → post = (10-4)×0.6×0.85/(7-4)      = 1.02
///                                                          DEX:  4.0 < 4.0/0.6    = 6.67
///     USDF mod:   seize 4.0 USDF,      repay 3.0 FLOW  → post = (10-4)×0.6×0.85/(6-3)      = 1.02
///                                                          DEX:  4.0 < 3.0/0.6    = 5.00
///     USDC high:  seize 0.8 USDC,      repay 0.8 FLOW  → post = (2-0.8)×0.6×0.85/(1.4-0.8) = 1.02
///                                                          DEX:  0.8 < 0.8/0.6    = 1.33
///     USDC mod:   seize 0.8 USDC,      repay 0.6 FLOW  → post = (2-0.8)×0.6×0.85/(1.2-0.6) = 1.02
///                                                          DEX:  0.8 < 0.6/0.6    = 1.00
///     WBTC:       seize 0.00003 WBTC,  repay 1.18 FLOW → post = (0.00006)×22500/(2.5-1.18)  = 1.023
///                                                          DEX:  0.00003 < 1.18/30000 = 0.0000393
///
///   Batch order (worst health first): USDF-high (0.729) → USDC-high (0.729) → WBTC (0.810) → USDF-mod (0.850) → USDC-mod (0.850)
///
/// Token budget (mainnet):
///   flowHolder  (1921 FLOW): 450 LP + 230 DEX source = 680 FLOW total
///   usdfHolder (25000 USDF): 500 USDF for 50 positions
///   usdcHolder    (97 USDC): 90 USDC for 45 positions
///   wbtcHolder (0.0005 WBTC): 0.00045 WBTC for 5 positions (holder has 0.00049998)
access(all) fun testMassUnhealthyLiquidations() {
    safeReset()

    log("=== Stress Test: 100 Positions (USDF/USDC/WBTC) Simultaneously Unhealthy ===\n")

    let lpUser     = Test.createAccount()
    let user       = Test.createAccount()
    let liquidator = Test.createAccount()

    //////////// LP setup ///////////////////

    // LP deposits 450 FLOW — covers the ~397 FLOW of total borrows with headroom.
    log("LP depositing 450 FLOW to shared liquidity pool\n")
    transferTokensFromHolder(holder: flowHolder, recipient: lpUser, amount: 450.0, storagePath: FLOW_VAULT_STORAGE_PATH, tokenName: "FLOW")
    createPosition(admin: protocolAccount, signer: lpUser, amount: 450.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    //////////// Transfer collateral to user ///////////////////

    // Group A: 50 positions × 10 USDF = 500 USDF
    // Group B: 45 positions × 2 USDC  = 90 USDC
    // Group C:  5 positions × 0.00009 WBTC = 0.00045 WBTC
    log("Transferring collateral: 500 USDF + 90 USDC + 0.00045 WBTC\n")
    transferTokensFromHolder(holder: usdfHolder, recipient: user, amount: 500.0, storagePath: USDF_VAULT_STORAGE_PATH, tokenName: "USDF")
    transferTokensFromHolder(holder: usdcHolder, recipient: user, amount: 90.0,  storagePath: USDC_VAULT_STORAGE_PATH, tokenName: "USDC")
    transferTokensFromHolder(holder: wbtcHolder, recipient: user, amount: 0.00045, storagePath: WBTC_VAULT_STORAGE_PATH, tokenName: "WBTC")

    //////////// Create 100 positions ///////////////////

    var allPids: [UInt64] = []

    // Group A — 50 USDF positions
    log("Creating 50 USDF positions (10 USDF each)...\n")
    for i in InclusiveRange(0, 49) {
        createPosition(admin: protocolAccount, signer: user, amount: 10.0, vaultStoragePath: USDF_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
        let openEvts = Test.eventsOfType(Type<FlowALPv0.Opened>())
        allPids.append((openEvts[openEvts.length - 1] as! FlowALPv0.Opened).pid)
    }

    // Group B — 45 USDC positions
    log("Creating 45 USDC positions (2 USDC each)...\n")
    for i in InclusiveRange(50, 94) {
        createPosition(admin: protocolAccount, signer: user, amount: 2.0, vaultStoragePath: USDC_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
        let openEvts = Test.eventsOfType(Type<FlowALPv0.Opened>())
        allPids.append((openEvts[openEvts.length - 1] as! FlowALPv0.Opened).pid)
    }

    // Group C — 5 WBTC positions
    log("Creating 5 WBTC positions (0.00009 WBTC each)...\n")
    for i in InclusiveRange(95, 99) {
        createPosition(admin: protocolAccount, signer: user, amount: 0.00009, vaultStoragePath: WBTC_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
        let openEvts = Test.eventsOfType(Type<FlowALPv0.Opened>())
        allPids.append((openEvts[openEvts.length - 1] as! FlowALPv0.Opened).pid)
    }

    Test.assert(allPids.length == 100, message: "Expected 100 positions, got \(allPids.length)")

    //////////// Borrow FLOW from each position ///////////////////

    // Group A — USDF positions:
    //   high-risk [0..24]:  borrow 7.0 FLOW → health = (10×1.0×0.85)/7.0  = 1.214
    //   moderate  [25..49]: borrow 6.0 FLOW → health = (10×1.0×0.85)/6.0  = 1.417
    log("Borrowing FLOW from 50 USDF positions...\n")
    for i in InclusiveRange(0, 24) {
        borrowFromPosition(signer: user, positionId: allPids[i], tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER_MAINNET, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, amount: 7.0, beFailed: false)
    }
    for i in InclusiveRange(25, 49) {
        borrowFromPosition(signer: user, positionId: allPids[i], tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER_MAINNET, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, amount: 6.0, beFailed: false)
    }

    // Group B — USDC positions:
    //   high-risk [50..72]: borrow 1.4 FLOW → health = (2×1.0×0.85)/1.4  = 1.214
    //   moderate  [73..94]: borrow 1.2 FLOW → health = (2×1.0×0.85)/1.2  = 1.417
    log("Borrowing FLOW from 45 USDC positions...\n")
    for i in InclusiveRange(50, 72) {
        borrowFromPosition(signer: user, positionId: allPids[i], tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER_MAINNET, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, amount: 1.4, beFailed: false)
    }
    for i in InclusiveRange(73, 94) {
        borrowFromPosition(signer: user, positionId: allPids[i], tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER_MAINNET, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, amount: 1.2, beFailed: false)
    }

    // Group C — WBTC positions:
    //   uniform  [95..99]: borrow 2.5 FLOW → health = (0.00009×50000×0.75)/2.5 = 1.350
    log("Borrowing FLOW from 5 WBTC positions...\n")
    for i in InclusiveRange(95, 99) {
        borrowFromPosition(signer: user, positionId: allPids[i], tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER_MAINNET, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, amount: 2.5, beFailed: false)
    }

    // Confirm all 100 positions are healthy before the crash
    for i in InclusiveRange(0, 99) {
        let health = getPositionHealth(pid: allPids[i], beFailed: false)
        Test.assert(health > 1.0, message: "Position \(allPids[i]) must be healthy before crash (got \(health))")
    }

    //////////// Simulate 40% price crash across all three collateral types ///////////////////

    // USDF/USDC: $1.00 → $0.60 (-40%)  |  WBTC: $50000 → $30000 (-40%)
    //
    // Health after crash:
    //   USDF high: (10×0.60×0.85)/7.0        = 0.729   USDF mod:  (10×0.60×0.85)/6.0       = 0.850
    //   USDC high: (2×0.60×0.85)/1.4         = 0.729   USDC mod:  (2×0.60×0.85)/1.2        = 0.850
    //   WBTC:      (0.00009×30000×0.75)/2.5  = 0.810
    log("All three collateral types crash 40% simultaneously\n")
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: USDF_TOKEN_IDENTIFIER, price: 0.6)
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: USDC_TOKEN_IDENTIFIER, price: 0.6)
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: WBTC_TOKEN_IDENTIFIER, price: 30000.0)

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

    // Three DEX pairs (all source FLOW from protocolAccount's vault):
    //   USDF→FLOW at priceRatio=0.6    ($0.60 USDF / $1.00 FLOW)
    //   USDC→FLOW at priceRatio=0.6    ($0.60 USDC / $1.00 FLOW)
    //   WBTC→FLOW at priceRatio=30000  ($30000 WBTC / $1.00 FLOW)
    //
    // Total DEX FLOW: 25×4.0 + 25×3.0 + 23×0.8 + 22×0.6 + 5×1.18
    //               = 100 + 75 + 18.4 + 13.2 + 5.90 = 212.50; transfer 230 for headroom
    log("Configuring DEX pairs: USDF→FLOW, USDC→FLOW, WBTC→FLOW\n")
    transferTokensFromHolder(holder: flowHolder, recipient: protocolAccount, amount: 230.0, storagePath: FLOW_VAULT_STORAGE_PATH, tokenName: "FLOW")
    setMockDexPriceForPair(
        signer: protocolAccount,
        inVaultIdentifier: USDF_TOKEN_IDENTIFIER,
        outVaultIdentifier: FLOW_TOKEN_IDENTIFIER_MAINNET,
        vaultSourceStoragePath: FLOW_VAULT_STORAGE_PATH,
        priceRatio: 0.6      // $0.60 USDF / $1.00 FLOW
    )
    setMockDexPriceForPair(
        signer: protocolAccount,
        inVaultIdentifier: USDC_TOKEN_IDENTIFIER,
        outVaultIdentifier: FLOW_TOKEN_IDENTIFIER_MAINNET,
        vaultSourceStoragePath: FLOW_VAULT_STORAGE_PATH,
        priceRatio: 0.6      // $0.60 USDC / $1.00 FLOW
    )
    setMockDexPriceForPair(
        signer: protocolAccount,
        inVaultIdentifier: WBTC_TOKEN_IDENTIFIER,
        outVaultIdentifier: FLOW_TOKEN_IDENTIFIER_MAINNET,
        vaultSourceStoragePath: FLOW_VAULT_STORAGE_PATH,
        priceRatio: 30000.0  // $30000 WBTC / $1.00 FLOW
    )

    //////////// Build batch parameters (ordered worst health first) ///////////////////
    //
    // Seize/repay parameters:
    //   USDF high  [0..24]:  seize 4.0 USDF,      repay 4.0 FLOW  post=1.02,  DEX: 4<6.67
    //   USDC high [50..72]:  seize 0.8 USDC,      repay 0.8 FLOW  post=1.02,  DEX: 0.8<1.33
    //   WBTC      [95..99]:  seize 0.00003 WBTC,  repay 1.18 FLOW post=1.023, DEX: 0.00003<0.0000393
    //   USDF mod  [25..49]:  seize 4.0 USDF,      repay 3.0 FLOW  post=1.02,  DEX: 4<5.00
    //   USDC mod  [73..94]:  seize 0.8 USDC,      repay 0.6 FLOW  post=1.02,  DEX: 0.8<1.00
    var batchPids:    [UInt64] = []
    var batchSeize:   [String] = []
    var batchAmounts: [UFix64] = []
    var batchRepay:   [UFix64] = []

    // USDF high-risk [0..24]
    for i in InclusiveRange(0, 24) {
        batchPids.append(allPids[i])
        batchSeize.append(USDF_TOKEN_IDENTIFIER)
        batchAmounts.append(4.0)
        batchRepay.append(4.0)
    }
    // USDC high-risk [50..72]
    for i in InclusiveRange(50, 72) {
        batchPids.append(allPids[i])
        batchSeize.append(USDC_TOKEN_IDENTIFIER)
        batchAmounts.append(0.8)
        batchRepay.append(0.8)
    }
    // WBTC uniform [95..99]
    for i in InclusiveRange(95, 99) {
        batchPids.append(allPids[i])
        batchSeize.append(WBTC_TOKEN_IDENTIFIER)
        batchAmounts.append(0.00003)
        batchRepay.append(1.18)
    }
    // USDF moderate [25..49]
    for i in InclusiveRange(25, 49) {
        batchPids.append(allPids[i])
        batchSeize.append(USDF_TOKEN_IDENTIFIER)
        batchAmounts.append(4.0)
        batchRepay.append(3.0)
    }
    // USDC moderate [73..94]
    for i in InclusiveRange(73, 94) {
        batchPids.append(allPids[i])
        batchSeize.append(USDC_TOKEN_IDENTIFIER)
        batchAmounts.append(0.8)
        batchRepay.append(0.6)
    }

    Test.assert(batchPids.length == 100, message: "Expected 100 batch entries, got \(batchPids.length)")

    //////////// Batch liquidation — 100 positions in chunks of 10 ///////////////////

    // Split into chunks of 10 to stay within the computation limit (single tx of 100 exceeds it).
    // DEX sources FLOW from protocolAccount's vault; liquidator needs no tokens upfront.
    log("Liquidating all 100 positions via DEX in chunks of 10...\n")
    batchLiquidateViaMockDex(
        pids: batchPids,
        debtVaultIdentifier: FLOW_TOKEN_IDENTIFIER_MAINNET,
        seizeVaultIdentifiers: batchSeize,
        seizeAmounts: batchAmounts,
        repayAmounts: batchRepay,
        chunkSize: 10,
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
        Test.assert(h > usdcHealths[i], message: "USDC pos \(allPids[i]) health must improve: \(usdcHealths[i]) → \(h)")
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
    let reserveBalance = getReserveBalance(vaultIdentifier: FLOW_TOKEN_IDENTIFIER_MAINNET)
    log("Protocol FLOW reserve after mass liquidation: \(reserveBalance)\n")
    Test.assert(reserveBalance > 0.0, message: "Protocol must remain solvent (positive FLOW reserve) after mass liquidation")
}
