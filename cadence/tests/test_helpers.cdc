import Test
import "TidalProtocol"

/* --- Global test constants --- */

access(all) let defaultTokenIdentifier = "A.0000000000000007.MOET.Vault"
access(all) let defaultUFixVariance = 0.00000001
access(all) let defaultUIntVariance: UInt128 = 1_000_000_000_000_000

// Health values
access(all) let minHealth = 1.1
access(all) let targetHealth = 1.3
access(all) let maxHealth = 1.5
access(all) var intMinHealth: UInt128 = 1_100_000_000_000_000_000_000_000
access(all) var intTargetHealth: UInt128 = 1_300_000_000_000_000_000_000_000
access(all) var intMaxHealth: UInt128 = 1_500_000_000_000_000_000_000_000
access(all) let ceilingHealth = UInt128.max      // the maximum health value when health is virtually infinite AKA debt ~0.0

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
        name: "DeFiActionsUtils",
        path: "../../DeFiActions/cadence/contracts/utils/DeFiActionsUtils.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    err = Test.deployContract(
        name: "DeFiActionsMathUtils",
        path: "../../DeFiActions/cadence/contracts/utils/DeFiActionsMathUtils.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    err = Test.deployContract(
        name: "DeFiActions",
        path: "../../DeFiActions/cadence/contracts/interfaces/DeFiActions.cdc",
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

    // Seed a Pool capability with EParticipant+EPosition entitlements in the protocol account's storage
    // so tests that use MockTidalProtocolConsumer can create positions via the Pool before any per-file setup.
    let protocolAccount = Test.getAccount(0x0000000000000007)
    let pubRes = _executeTransaction(
        "../transactions/tidal-protocol/beta/publish_beta_cap.cdc",
        [protocolAccount.address],
        protocolAccount
    )
    Test.expect(pubRes, Test.beSucceeded())
    let claimRes = _executeTransaction(
        "../transactions/tidal-protocol/beta/claim_and_save_beta_cap.cdc",
        [protocolAccount.address],
        protocolAccount
    )
    Test.expect(claimRes, Test.beSucceeded())

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

    let initialYieldTokenSupply = 0.0
    err = Test.deployContract(
        name: "MockYieldToken",
        path: "../contracts/mocks/MockYieldToken.cdc",
        arguments: [initialYieldTokenSupply]
    )
    Test.expect(err, Test.beNil())

    // Deploy FungibleTokenConnectors
    err = Test.deployContract(
        name: "FungibleTokenConnectors",
        path: "../../DeFiActions/cadence/contracts/connectors/FungibleTokenConnectors.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    // Deploy MockDexSwapper for DEX liquidation tests
    err = Test.deployContract(
        name: "MockDexSwapper",
        path: "../contracts/mocks/MockDexSwapper.cdc",
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
fun getPositionHealth(pid: UInt64, beFailed: Bool): UInt128 {
    let res = _executeScript("../scripts/tidal-protocol/position_health.cdc",
            [pid]
        )
    Test.expect(res, beFailed ? Test.beFailed() : Test.beSucceeded())
    return res.status == Test.ResultStatus.failed ? 0 : res.returnValue as! UInt128
}

access(all)
fun getPositionDetails(pid: UInt64, beFailed: Bool): TidalProtocol.PositionDetails {
    let res = _executeScript("../scripts/tidal-protocol/position_details.cdc",
            [pid]
        )
    Test.expect(res, beFailed ? Test.beFailed() : Test.beSucceeded())
    return res.returnValue as! TidalProtocol.PositionDetails
}

access(all)
fun poolExists(address: Address): Bool {
    let res = _executeScript("../scripts/tidal-protocol/pool_exists.cdc", [address])
    Test.expect(res, Test.beSucceeded())
    return res.returnValue as! Bool
}

access(all)
fun fundsAvailableAboveTargetHealthAfterDepositing(
    pid: UInt64,
    withdrawType: String,
    targetHealth: UInt128,
    depositType: String,
    depositAmount: UFix64,
    beFailed: Bool
): UFix64 {
    let res = _executeScript("../scripts/tidal-protocol/funds_avail_above_target_health_after_deposit.cdc",
            [pid, withdrawType, targetHealth, depositType, depositAmount]
        )
    Test.expect(res, beFailed ? Test.beFailed() : Test.beSucceeded())
    return res.returnValue as! UFix64
}

access(all)
fun fundsRequiredForTargetHealthAfterWithdrawing(
    pid: UInt64,
    depositType: String,
    targetHealth: UInt128,
    withdrawType: String,
    withdrawAmount: UFix64,
    beFailed: Bool
): UFix64 {
    let res = _executeScript("../scripts/tidal-protocol/funds_req_for_target_health_after_withdraw.cdc",
            [pid, depositType, targetHealth, withdrawType, withdrawAmount]
        )
    Test.expect(res, beFailed ? Test.beFailed() : Test.beSucceeded())
    return res.returnValue as! UFix64
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

/* --- Capability Helpers --- */

// Grants the Pool capability with EParticipant and EPosition entitlements to the MockTidalProtocolConsumer account (0x8)
// Must be called AFTER the pool is created and stored, otherwise publishing will fail the capability check.
access(all)
fun grantPoolCapToConsumer() {
    let protocolAccount = Test.getAccount(0x0000000000000007)
    let consumerAccount = Test.getAccount(0x0000000000000008)

    let publishRes = _executeTransaction(
        "../transactions/tidal-protocol/beta/publish_beta_cap.cdc",
        [consumerAccount.address],
        protocolAccount
    )
    Test.expect(publishRes, Test.beSucceeded())

    let claimRes = _executeTransaction(
        "../transactions/tidal-protocol/beta/claim_and_save_beta_cap.cdc",
        [protocolAccount.address],
        consumerAccount
    )
    Test.expect(claimRes, Test.beSucceeded())
}
/* --- Assertion Helpers --- */

access(all) fun equalWithinVariance(_ expected: AnyStruct, _ actual: AnyStruct): Bool {
    let expectedType = expected.getType()
    let actualType = actual.getType()
    if expectedType == Type<UFix64>() && actualType == Type<UFix64>() {
        return ufixEqualWithinVariance(expected as! UFix64, actual as! UFix64)
    } else if expectedType == Type<UInt128>() && actualType == Type<UInt128>() {
        return uintEqualWithinVariance(expected as! UInt128, actual as! UInt128)
    }
    panic("Expected and actual types do not match - expected: \(expectedType.identifier), actual: \(actualType.identifier)")
}

access(all) fun ufixEqualWithinVariance(_ expected: UFix64, _ actual: UFix64): Bool {
    // return true if expected is within defaultUFixVariance of actual, false otherwise and protect for underflow`
    let diff = Fix64(expected) - Fix64(actual)
    // take the absolute value of the difference without relying on .abs()
    let absDiff: UFix64 = diff < 0.0 ? UFix64(-1.0 * diff) : UFix64(diff)
    return absDiff <= defaultUFixVariance
}

access(all) fun uintEqualWithinVariance(_ expected: UInt128, _ actual: UInt128): Bool {
    let diff = Int128(expected) - Int128(actual)
    let absDiff: UInt128 = diff < 0 ? UInt128(Int128(-1) * diff) : UInt128(diff)
    return absDiff <= defaultUIntVariance
}
