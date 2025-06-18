import Test
// import "TidalProtocol"

access(all) let defaultTokenIdentifier = "A.0000000000000007.MOET.Vault"

/* --- Test execution helpers --- */

access(all)
fun _executeScript(_ path: String, _ args: [AnyStruct]): Test.ScriptResult {
    return Test.executeScript(Test.readFile(path), args)
}

access(all)
fun _executeTransaction(_ path: String, _ args: [AnyStruct], _ signer: Test.TestAccount): Test.TransactionResult {
    let txn = Test.Transaction(
        code: Test.readFile(path),
        authorizers: [signer.address],
        signers: [signer],
        arguments: args
    )    
    return Test.executeTransaction(txn)
}

/* --- Setup helpers --- */

// Common test setup function that deploys all required contracts
access(all)
fun deployContracts() {
    var err = Test.deployContract(
        name: "DFBUtils",
        path: "./mocks/DFBUtils.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    err = Test.deployContract(
        name: "DFB",
        path: "../../DeFiBlocks/cadence/contracts/interfaces/DFB.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    let initialSupply = 0.0
    err = Test.deployContract(
        name: "MOET",
        path: "../contracts/MOET.cdc",
        arguments: [initialSupply]
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "TidalProtocol",
        path: "../contracts/TidalProtocol.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    // Deploy MockTidalProtocolConsumer
    err = Test.deployContract(
        name: "MockTidalProtocolConsumer",
        path: "../contracts/mocks/MockTidalProtocolConsumer.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "MockOracle",
        path: "../contracts/mocks/MockOracle.cdc",
        arguments: [defaultTokenIdentifier]
    )
    Test.expect(err, Test.beNil())
    
    // Deploy FungibleTokenStack
    err = Test.deployContract(
        name: "FungibleTokenStack",
        path: "../../DeFiBlocks/cadence/contracts/connectors/FungibleTokenStack.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
}

/* --- Script Helpers --- */

access(all)
fun getBalance(address: Address, vaultPublicPath: PublicPath): UFix64? {
    let res = _executeScript("../scripts/tokens/get_balance.cdc", [address, vaultPublicPath])
    Test.expect(res, Test.beSucceeded())
    return res.returnValue as! UFix64?
}

access(all)
fun getReserveBalance(vaultIdentifier: String): UFix64 {
    let res = _executeScript("../scripts/tidal-protocol/get_reserve_balance_for_type.cdc", [vaultIdentifier])
    Test.expect(res, Test.beSucceeded())
    return res.returnValue as! UFix64
}

access(all)
fun getAvailableBalance(pid: UInt64, vaultIdentifier: String, pullFromTopUpSource: Bool, beFailed: Bool): UFix64 {
    let res = _executeScript("../scripts/tidal-protocol/get_available_balance.cdc",
            [pid, vaultIdentifier, pullFromTopUpSource]
        )
    Test.expect(res, beFailed ? Test.beFailed() : Test.beSucceeded())
    return res.status == Test.ResultStatus.failed ? 0.0 : res.returnValue as! UFix64
}

access(all)
fun getPositionHealth(pid: UInt64, beFailed: Bool): UFix64 {
    let res = _executeScript("../scripts/tidal-protocol/position_health.cdc",
            [pid]
        )
    Test.expect(res, beFailed ? Test.beFailed() : Test.beSucceeded())
    return res.status == Test.ResultStatus.failed ? 0.0 : res.returnValue as! UFix64
}

access(all)
fun poolExists(address: Address): Bool {
    let res = _executeScript("../scripts/tidal-protocol/pool_exists.cdc", [address])
    Test.expect(res, Test.beSucceeded())
    return res.returnValue as! Bool
}

/* --- Transaction Helpers --- */

access(all)
fun createAndStorePool(signer: Test.TestAccount, defaultTokenIdentifier: String, beFailed: Bool) {
    let createRes = _executeTransaction(
        "../transactions/tidal-protocol/pool-factory/create_and_store_pool.cdc",
        [defaultTokenIdentifier],
        signer
    )
    Test.expect(createRes, beFailed ? Test.beFailed() : Test.beSucceeded())
}

access(all)
fun setMockOraclePrice(signer: Test.TestAccount, forTokenIdentifier: String, price: UFix64) {
    let setRes = _executeTransaction(
        "./transactions/mock-oracle/set_price.cdc",
        [forTokenIdentifier, price],
        signer
    )
    Test.expect(setRes, Test.beSucceeded())
}

access(all)
fun addSupportedTokenSimpleInterestCurve(
    signer: Test.TestAccount,
    tokenTypeIdentifier: String,
    collateralFactor: UFix64,
    borrowFactor: UFix64,
    depositRate: UFix64,
    depositCapacityCap: UFix64
) {
    let additionRes = _executeTransaction(
        "../transactions/tidal-protocol/pool-governance/add_supported_token_simple_interest_curve.cdc",
        [ tokenTypeIdentifier, collateralFactor, borrowFactor, depositRate, depositCapacityCap ],
        signer
    )
    Test.expect(additionRes, Test.beSucceeded())
}

access(all)
fun addSupportedTokenSimpleInterestCurveWithResult(
    signer: Test.TestAccount,
    tokenTypeIdentifier: String,
    collateralFactor: UFix64,
    borrowFactor: UFix64,
    depositRate: UFix64,
    depositCapacityCap: UFix64
): Test.TransactionResult {
    return _executeTransaction(
        "../transactions/tidal-protocol/pool-governance/add_supported_token_simple_interest_curve.cdc",
        [ tokenTypeIdentifier, collateralFactor, borrowFactor, depositRate, depositCapacityCap ],
        signer
    )
}

access(all)
fun rebalancePosition(signer: Test.TestAccount, pid: UInt64, force: Bool, beFailed: Bool) {
    let rebalanceRes = _executeTransaction(
        "../transactions/tidal-protocol/pool-management/rebalance_position.cdc",
        [ pid, force ],
        signer
    )
    Test.expect(rebalanceRes, beFailed ? Test.beFailed() : Test.beSucceeded())
}

access(all)
fun setupMoetVault(_ signer: Test.TestAccount, beFailed: Bool) {
    let setupRes = _executeTransaction("../transactions/moet/setup_vault.cdc", [], signer)
    Test.expect(setupRes, beFailed ? Test.beFailed() : Test.beSucceeded())
}

access(all)
fun mintMoet(signer: Test.TestAccount, to: Address, amount: UFix64, beFailed: Bool) {
    let mintRes = _executeTransaction("../transactions/moet/mint_moet.cdc", [to, amount], signer)
    Test.expect(mintRes, beFailed ? Test.beFailed() : Test.beSucceeded())
}


// Transfer Flow tokens from service account to recipient
access(all)
fun transferFlowTokens(to: Test.TestAccount, amount: UFix64) {
    let transferTx = Test.Transaction(
        code: Test.readFile("../transactions/flowtoken/transfer_flowtoken.cdc"),
        authorizers: [Test.serviceAccount().address],
        signers: [Test.serviceAccount()],
        arguments: [to.address, amount]
    )
    let res = Test.executeTransaction(transferTx)
    Test.expect(res, Test.beSucceeded())
}


access(all)
fun expectEvents(eventType: Type, expectedCount: Int) {
    let events = Test.eventsOfType(eventType)
    Test.assertEqual(expectedCount, events.length)
}

access(all)
fun withdrawReserve(
    signer: Test.TestAccount,
    poolAddress: Address,
    tokenTypeIdentifier: String,
    amount: UFix64,
    recipient: Address,
    beFailed: Bool
) {
    let txRes = _executeTransaction(
        "../transactions/tidal-protocol/pool-governance/withdraw_reserve.cdc",
        [poolAddress, tokenTypeIdentifier, amount, recipient],
        signer
    )
    Test.expect(txRes, beFailed ? Test.beFailed() : Test.beSucceeded())
}

/* --- Snapshot Management Helpers --- */

// Example usage pattern for managing blockchain state between tests:
//
// In your test file:
// ```
// access(all) var snapshot: UInt64 = 0
// 
// access(all) fun setup() {
//     deployContracts()
//     snapshot = getCurrentBlockHeight()
// }
// 
// access(all) fun testExample() {
//     Test.reset(to: snapshot) // Reset to clean state
//     // ... your test logic ...
// }
// ```
