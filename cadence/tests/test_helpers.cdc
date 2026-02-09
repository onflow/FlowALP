import Test
import "FlowCreditMarket"

/* --- Global test constants --- */

access(all) let MOET_TOKEN_IDENTIFIER = "A.0000000000000007.MOET.Vault"
access(all) let FLOW_TOKEN_IDENTIFIER = "A.0000000000000003.FlowToken.Vault"
access(all) let FLOW_VAULT_STORAGE_PATH = /storage/flowTokenVault
access(all) let WRAPPER_STORAGE_PATH = /storage/flowCreditMarketPositionWrapper

access(all) let PROTOCOL_ACCOUNT = Test.getAccount(0x0000000000000007)
access(all) let NON_ADMIN_ACCOUNT = Test.getAccount(0x0000000000000008)

// Variance for UFix64 comparisons
access(all) let DEFAULT_UFIX_VARIANCE = 0.00000001
// Variance for UFix128 comparisons
access(all) let DEFAULT_UFIX128_VARIANCE: UFix128 = 0.00000001

// Health values
access(all) let MIN_HEALTH = 1.1
access(all) let TARGET_HEALTH = 1.3
access(all) let MAX_HEALTH = 1.5
// UFix128 equivalents
access(all) let INT_MIN_HEALTH: UFix128 = 1.1
access(all) let INT_TARGET_HEALTH: UFix128 = 1.3
access(all) let INT_MAX_HEALTH: UFix128 = 1.5
access(all) let CEILING_HEALTH: UFix128 = UFix128.max      // infinite health when debt ~ 0.0

// Time constants
access(all) let DAY: Fix64 = 86_400.0
access(all) let TEN_DAYS: Fix64 = 864_000.0
access(all) let THIRTY_DAYS: Fix64 = 2_592_000.0   // 30 * 86400
access(all) let ONE_YEAR: Fix64 = 31_557_600.0     // 365.25 * 86400


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

// Grants a beta pool participant capability to the grantee account.
access(all)
fun grantBetaPoolParticipantAccess(_ admin: Test.TestAccount, _ grantee: Test.TestAccount) {
    let signers = admin.address == grantee.address ? [admin] : [admin, grantee]
    let betaTxn = Test.Transaction(
        code: Test.readFile("./transactions/flow-credit-market/pool-management/03_grant_beta.cdc"),
        authorizers: [admin.address, grantee.address],
        signers: signers,
        arguments: []
    )
    let result = Test.executeTransaction(betaTxn)
    Test.expect(result, Test.beSucceeded())
}

/* --- Setup helpers --- */

// Common test setup function that deploys all required contracts
access(all)
fun deployContracts() {
    var err = Test.deployContract(
        name: "DeFiActionsUtils",
        path: "../../FlowActions/cadence/contracts/utils/DeFiActionsUtils.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    // Deploy FlowCreditMarketMath before FlowCreditMarket
    err = Test.deployContract(
        name: "FlowCreditMarketMath",
        path: "../lib/FlowCreditMarketMath.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    err = Test.deployContract(
        name: "DeFiActions",
        path: "../../FlowActions/cadence/contracts/interfaces/DeFiActions.cdc",
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
        name: "FlowCreditMarket",
        path: "../contracts/FlowCreditMarket.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "MockOracle",
        path: "../contracts/mocks/MockOracle.cdc",
        arguments: [MOET_TOKEN_IDENTIFIER]
    )
    Test.expect(err, Test.beNil())

    let initialYieldTokenSupply = 0.0
    err = Test.deployContract(
        name: "MockYieldToken",
        path: "../contracts/mocks/MockYieldToken.cdc",
        arguments: [initialYieldTokenSupply]
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "DummyConnectors",
        path: "../contracts/mocks/DummyConnectors.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    // Deploy FungibleTokenConnectors
    err = Test.deployContract(
        name: "FungibleTokenConnectors",
        path: "../../FlowActions/cadence/contracts/connectors/FungibleTokenConnectors.cdc",
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

    err = Test.deployContract(
        name: "AdversarialReentrancyConnectors",
        path: "./contracts/AdversarialReentrancyConnectors.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())


    err = Test.deployContract(
        name: "AdversarialTypeSpoofingConnectors",
        path: "./contracts/AdversarialTypeSpoofingConnectors.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "FlowCreditMarketRebalancerV1",
        path: "../contracts/FlowCreditMarketRebalancerV1.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "FlowCreditMarketRebalancerPaidV1",
        path: "../contracts/FlowCreditMarketRebalancerPaidV1.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "FlowCronUtils",
        path: "../../imports/6dec6e64a13b881e/FlowCronUtils.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "FlowCron",
        path: "../../imports/6dec6e64a13b881e/FlowCron.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "FlowCreditMarketSupervisorV1",
        path: "../contracts/FlowCreditMarketSupervisorV1.cdc",
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
    let res = _executeScript("../scripts/flow-credit-market/get_reserve_balance_for_type.cdc", [vaultIdentifier])
    Test.expect(res, Test.beSucceeded())
    return res.returnValue as! UFix64
}

access(all)
fun getAvailableBalance(pid: UInt64, vaultIdentifier: String, pullFromTopUpSource: Bool, beFailed: Bool): UFix64 {
    let res = _executeScript("../scripts/flow-credit-market/get_available_balance.cdc",
            [pid, vaultIdentifier, pullFromTopUpSource]
        )
    Test.expect(res, beFailed ? Test.beFailed() : Test.beSucceeded())
    return res.status == Test.ResultStatus.failed ? 0.0 : res.returnValue as! UFix64
}

access(all)
fun getPositionHealth(pid: UInt64, beFailed: Bool): UFix128 {
    let res = _executeScript("../scripts/flow-credit-market/position_health.cdc",
            [pid]
        )
    Test.expect(res, beFailed ? Test.beFailed() : Test.beSucceeded())
    return res.status == Test.ResultStatus.failed ? 0.0 : res.returnValue as! UFix128
}

access(all)
fun getPositionDetails(pid: UInt64, beFailed: Bool): FlowCreditMarket.PositionDetails {
    let res = _executeScript("../scripts/flow-credit-market/position_details.cdc",
            [pid]
        )
    Test.expect(res, beFailed ? Test.beFailed() : Test.beSucceeded())
    return res.returnValue as! FlowCreditMarket.PositionDetails
}

access(all)
fun getPositionBalance(pid: UInt64, vaultID: String): FlowCreditMarket.PositionBalance {
    let positionDetails = getPositionDetails(pid: pid, beFailed: false)
    for bal in positionDetails.balances {
        if bal.vaultType == CompositeType(vaultID) {
            return bal
        }
    }
    panic("expected to find balance for \(vaultID) in position\(pid)")
}

access(all)
fun poolExists(address: Address): Bool {
    let res = _executeScript("../scripts/flow-credit-market/pool_exists.cdc", [address])
    Test.expect(res, Test.beSucceeded())
    return res.returnValue as! Bool
}

access(all)
fun fundsAvailableAboveTargetHealthAfterDepositing(
    pid: UInt64,
    withdrawType: String,
    targetHealth: UFix128,
    depositType: String,
    depositAmount: UFix64,
    beFailed: Bool
): UFix64 {
    let res = _executeScript("../scripts/flow-credit-market/funds_avail_above_target_health_after_deposit.cdc",
            [pid, withdrawType, targetHealth, depositType, depositAmount]
        )
    Test.expect(res, beFailed ? Test.beFailed() : Test.beSucceeded())
    return res.returnValue as! UFix64
}

access(all)
fun fundsRequiredForTargetHealthAfterWithdrawing(
    pid: UInt64,
    depositType: String,
    targetHealth: UFix128,
    withdrawType: String,
    withdrawAmount: UFix64,
    beFailed: Bool
): UFix64 {
    let res = _executeScript("../scripts/flow-credit-market/funds_req_for_target_health_after_withdraw.cdc",
            [pid, depositType, targetHealth, withdrawType, withdrawAmount]
        )
    Test.expect(res, beFailed ? Test.beFailed() : Test.beSucceeded())
    return res.returnValue as! UFix64
}

access(all)
fun getDepositCapacityInfo(vaultIdentifier: String): {String: UFix64} {
    let res = _executeScript("../scripts/flow-credit-market/get_deposit_capacity.cdc", [vaultIdentifier])
    Test.expect(res, Test.beSucceeded())
    return res.returnValue as! {String: UFix64}
}

access(all)
fun getInsuranceFundBalance(): UFix64 {
    let res = _executeScript("../scripts/flow-credit-market/get_insurance_fund_balance.cdc", [])
    Test.expect(res, Test.beSucceeded())
    return res.returnValue as! UFix64
}

access(all)
fun getInsuranceRate(tokenTypeIdentifier: String): UFix64? {
    let res = _executeScript("../scripts/flow-credit-market/get_insurance_rate.cdc", [tokenTypeIdentifier])
    Test.expect(res, Test.beSucceeded())
    return res.returnValue as? UFix64
}

access(all)
fun insuranceSwapperExists(tokenTypeIdentifier: String): Bool {
    let res = _executeScript("../scripts/flow-credit-market/insurance_token_swapper_exists.cdc", [tokenTypeIdentifier])
    Test.expect(res, Test.beSucceeded())
    return res.returnValue as! Bool
}

access(all)
fun getLastInsuranceCollectionTime(tokenTypeIdentifier: String): UFix64? {
    let res = _executeScript("../scripts/flow-credit-market/get_last_insurance_collection_time.cdc", [tokenTypeIdentifier])
    Test.expect(res, Test.beSucceeded())
    return res.returnValue as? UFix64
}

access(all)
fun getStabilityFeeRate(tokenTypeIdentifier: String): UFix64? {
    let res = _executeScript("../scripts/flow-credit-market/get_stability_fee_rate.cdc", [tokenTypeIdentifier])
    Test.expect(res, Test.beSucceeded())
    return res.returnValue as? UFix64
}

access(all)
fun getStabilityFundBalance(tokenTypeIdentifier: String): UFix64? {
    let res = _executeScript("../scripts/flow-credit-market/get_stability_fund_balance.cdc", [tokenTypeIdentifier])
    Test.expect(res, Test.beSucceeded())
    return res.returnValue as? UFix64
}

access(all)
fun getLastStabilityCollectionTime(tokenTypeIdentifier: String): UFix64? {
    let res = _executeScript("../scripts/flow-credit-market/get_last_stability_collection_time.cdc", [tokenTypeIdentifier])
    Test.expect(res, Test.beSucceeded())
    return res.returnValue as? UFix64
}

/* --- Transaction Helpers --- */

access(all)
fun createAndStorePool(signer: Test.TestAccount, defaultTokenIdentifier: String, beFailed: Bool) {
    let createRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-factory/create_and_store_pool.cdc",
        [defaultTokenIdentifier],
        signer
    )
    Test.expect(createRes, beFailed ? Test.beFailed() : Test.beSucceeded())

    // Enable debug logs for tests to aid diagnostics
    let debugRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-governance/set_debug_logging.cdc",
        [true],
        signer
    )
    Test.expect(debugRes, Test.beSucceeded())
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

/// Sets a swapper for the given pair with the given price ratio.
/// This overwrites any previously stored swapper for this pair, if any exists.
/// This is intended to be used in tests both to set an initial DEX price for a supported token,
/// or to modify the price of an existing token during the course of a test.
access(all)
fun setMockDexPriceForPair(
    signer: Test.TestAccount,
    inVaultIdentifier: String,
    outVaultIdentifier: String,
    vaultSourceStoragePath: StoragePath,
    priceRatio: UFix64
) {
    let addRes = _executeTransaction(
        "./transactions/mock-dex-swapper/set_mock_dex_price_for_pair.cdc",
        [inVaultIdentifier, outVaultIdentifier, vaultSourceStoragePath, priceRatio],
        signer
    )
    Test.expect(addRes, Test.beSucceeded())
}

access(all)
fun addSupportedTokenZeroRateCurve(
    signer: Test.TestAccount,
    tokenTypeIdentifier: String,
    collateralFactor: UFix64,
    borrowFactor: UFix64,
    depositRate: UFix64,
    depositCapacityCap: UFix64
) {
    let additionRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-governance/add_supported_token_zero_rate_curve.cdc",
        [ tokenTypeIdentifier, collateralFactor, borrowFactor, depositRate, depositCapacityCap ],
        signer
    )
    Test.expect(additionRes, Test.beSucceeded())
}

access(all)
fun addSupportedTokenZeroRateCurveWithResult(
    signer: Test.TestAccount,
    tokenTypeIdentifier: String,
    collateralFactor: UFix64,
    borrowFactor: UFix64,
    depositRate: UFix64,
    depositCapacityCap: UFix64
): Test.TransactionResult {
    return _executeTransaction(
        "../transactions/flow-credit-market/pool-governance/add_supported_token_zero_rate_curve.cdc",
        [ tokenTypeIdentifier, collateralFactor, borrowFactor, depositRate, depositCapacityCap ],
        signer
    )
}

access(all)
fun setDepositRate(signer: Test.TestAccount, tokenTypeIdentifier: String, hourlyRate: UFix64) {
    let setRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-governance/set_deposit_rate.cdc",
        [tokenTypeIdentifier, hourlyRate],
        signer
    )
    Test.expect(setRes, Test.beSucceeded())
}

access(all)
fun setDepositCapacityCap(signer: Test.TestAccount, tokenTypeIdentifier: String, cap: UFix64) {
    let setRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-governance/set_deposit_capacity_cap.cdc",
        [tokenTypeIdentifier, cap],
        signer
    )
    Test.expect(setRes, Test.beSucceeded())
}

access(all)
fun setDepositLimitFraction(signer: Test.TestAccount, tokenTypeIdentifier: String, fraction: UFix64) {
    let setRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-governance/set_deposit_limit_fraction.cdc",
        [tokenTypeIdentifier, fraction],
        signer
    )
    Test.expect(setRes, Test.beSucceeded())
}

access(all)
fun createPosition(signer: Test.TestAccount, amount: UFix64, vaultStoragePath: StoragePath, pushToDrawDownSink: Bool) {
    // Grant beta access to the signer if they don't have it yet
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, signer)

    let openRes = _executeTransaction(
        "../transactions/flow-credit-market/position/create_position.cdc",
        [amount, vaultStoragePath, pushToDrawDownSink],
        signer
    )
    Test.expect(openRes, Test.beSucceeded())
}

access(all)
fun createPositionNotManaged(signer: Test.TestAccount, amount: UFix64, vaultStoragePath: StoragePath, pushToDrawDownSink: Bool, positionStoragePath: StoragePath) {
    // Grant beta access to the signer if they don't have it yet
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, signer)

    let openRes = _executeTransaction(
        "../transactions/flow-credit-market/position/create_position_not_managed.cdc",
        [amount, vaultStoragePath, pushToDrawDownSink, positionStoragePath],
        signer
    )
    Test.expect(openRes, Test.beSucceeded())
}

access(all)
fun depositToPosition(signer: Test.TestAccount, positionID: UInt64, amount: UFix64, vaultStoragePath: StoragePath, pushToDrawDownSink: Bool) {
    let depositRes = _executeTransaction(
        "./transactions/position-manager/deposit_to_position.cdc",
        [positionID, amount, vaultStoragePath, pushToDrawDownSink],
        signer
    )
    Test.expect(depositRes, Test.beSucceeded())
}

access(all)
fun depositToPositionNotManaged(signer: Test.TestAccount, positionStoragePath: StoragePath, amount: UFix64, vaultStoragePath: StoragePath, pushToDrawDownSink: Bool) {
    let depositRes = _executeTransaction(
        "./transactions/position/deposit_to_position.cdc",
        [positionStoragePath, amount, vaultStoragePath, pushToDrawDownSink],
        signer
    )
    Test.expect(depositRes, Test.beSucceeded())
}

access(all)
fun borrowFromPosition(signer: Test.TestAccount, positionId: UInt64, tokenTypeIdentifier: String, amount: UFix64, beFailed: Bool) {
    let borrowRes = _executeTransaction(
        "./transactions/position-manager/borrow_from_position.cdc",
        [positionId, tokenTypeIdentifier, amount],
        signer
    )
    Test.expect(borrowRes, beFailed ? Test.beFailed() : Test.beSucceeded())
}

access(all)
fun addSupportedTokenKinkCurve(
    signer: Test.TestAccount,
    tokenTypeIdentifier: String,
    collateralFactor: UFix64,
    borrowFactor: UFix64,
    optimalUtilization: UFix128,
    baseRate: UFix128,
    slope1: UFix128,
    slope2: UFix128,
    depositRate: UFix64,
    depositCapacityCap: UFix64
) {
    let additionRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-governance/add_supported_token_kink_curve.cdc",
        [ tokenTypeIdentifier, collateralFactor, borrowFactor, optimalUtilization, baseRate, slope1, slope2, depositRate, depositCapacityCap ],
        signer
    )
    Test.expect(additionRes, Test.beSucceeded())
}

access(all)
fun setInterestCurveKink(
    signer: Test.TestAccount,
    tokenTypeIdentifier: String,
    optimalUtilization: UFix128,
    baseRate: UFix128,
    slope1: UFix128,
    slope2: UFix128
) {
    let setRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-governance/set_interest_curve_kink.cdc",
        [ tokenTypeIdentifier, optimalUtilization, baseRate, slope1, slope2 ],
        signer
    )
    Test.expect(setRes, Test.beSucceeded())
}

access(all)
fun setInterestCurveFixed(
    signer: Test.TestAccount,
    tokenTypeIdentifier: String,
    yearlyRate: UFix128
) {
    let setRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-governance/set_interest_curve_fixed.cdc",
        [ tokenTypeIdentifier, yearlyRate ],
        signer
    )
    Test.expect(setRes, Test.beSucceeded())
}

access(all)
fun setInsuranceRate(
    signer: Test.TestAccount,
    tokenTypeIdentifier: String,
    insuranceRate: UFix64,
): Test.TransactionResult {
    var res = _executeTransaction(
        "../transactions/flow-credit-market/pool-governance/set_insurance_rate.cdc",
        [ tokenTypeIdentifier, insuranceRate ],
        signer
    )
    return res
}

access(all)
fun setInsuranceSwapper(
    signer: Test.TestAccount,
    tokenTypeIdentifier: String,
    priceRatio: UFix64,
): Test.TransactionResult {
    let res = _executeTransaction(
        "./transactions/flow-credit-market/pool-governance/set_insurance_swapper_mock.cdc",
        [ tokenTypeIdentifier, priceRatio, tokenTypeIdentifier, MOET_TOKEN_IDENTIFIER],
        signer
    )
    return res
}

access(all)
fun removeInsuranceSwapper(
    signer: Test.TestAccount,
    tokenTypeIdentifier: String,
): Test.TransactionResult {
    let res = _executeTransaction(
        "./transactions/flow-credit-market/pool-governance/remove_insurance_swapper.cdc",
        [ tokenTypeIdentifier],
        signer
    )
    return res
}

access(all)
fun collectInsurance(
    signer: Test.TestAccount,
    tokenTypeIdentifier: String,
    beFailed: Bool
) {
    let collectRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-governance/collect_insurance.cdc",
        [ tokenTypeIdentifier ],
        signer
    )
    Test.expect(collectRes, beFailed ? Test.beFailed() : Test.beSucceeded())
}


access(all)
fun setStabilityFeeRate(
    signer: Test.TestAccount,
    tokenTypeIdentifier: String,
    stabilityFeeRate: UFix64
): Test.TransactionResult {
    let res = _executeTransaction(
        "../transactions/flow-credit-market/pool-governance/set_stability_fee_rate.cdc",
        [ tokenTypeIdentifier, stabilityFeeRate ],
        signer
    )

    return res
}

access(all)
fun collectStability(
    signer: Test.TestAccount,
    tokenTypeIdentifier: String,
): Test.TransactionResult {
    let res = _executeTransaction(
        "../transactions/flow-credit-market/pool-governance/collect_stability.cdc",
        [ tokenTypeIdentifier ],
        signer
    )
    
    return res
}

access(all)
fun withdrawStabilityFund(
    signer: Test.TestAccount,
    tokenTypeIdentifier: String,
    amount: UFix64,
    recipient: Address,
    recipientPath: PublicPath,
): Test.TransactionResult {
    let res = _executeTransaction(
        "../transactions/flow-credit-market/pool-governance/withdraw_stability_fund.cdc",
        [tokenTypeIdentifier, amount, recipient, recipientPath],
        signer
    )
    
    return res
}

access(all)
fun rebalancePosition(signer: Test.TestAccount, pid: UInt64, force: Bool, beFailed: Bool) {
    let rebalanceRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-management/rebalance_position.cdc",
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

access(all)
fun setupMockYieldTokenVault(_ signer: Test.TestAccount, beFailed: Bool) {
    let setupRes = _executeTransaction("../transactions/mocks/yieldtoken/setup_vault.cdc", [], signer)
    Test.expect(setupRes, beFailed ? Test.beFailed() : Test.beSucceeded())
}

access(all)
fun mintMockYieldToken(signer: Test.TestAccount, to: Address, amount: UFix64, beFailed: Bool) {
    let mintRes = _executeTransaction("../transactions/mocks/yieldtoken/mint.cdc", [to, amount], signer)
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
fun sendFlow(from: Test.TestAccount, to: Test.TestAccount, amount: UFix64) {
    let transferTx = Test.Transaction(
        code: Test.readFile("../transactions/flowtoken/transfer_flowtoken.cdc"),
        authorizers: [from.address],
        signers: [from],
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
        "../transactions/flow-credit-market/pool-governance/withdraw_reserve.cdc",
        [poolAddress, tokenTypeIdentifier, amount, recipient],
        signer
    )
    Test.expect(txRes, beFailed ? Test.beFailed() : Test.beSucceeded())
}

/* --- Assertion Helpers --- */

access(all) fun equalWithinVariance(_ expected: AnyStruct, _ actual: AnyStruct): Bool {
    let expectedType = expected.getType()
    let actualType = actual.getType()
    if expectedType == Type<UFix64>() && actualType == Type<UFix64>() {
        return ufixEqualWithinVariance(expected as! UFix64, actual as! UFix64)
    } else if expectedType == Type<UFix128>() && actualType == Type<UFix128>() {
        return ufix128EqualWithinVariance(expected as! UFix128, actual as! UFix128)
    }
    panic("Expected and actual types do not match - expected: \(expectedType.identifier), actual: \(actualType.identifier)")
}

access(all) fun ufixEqualWithinVariance(_ expected: UFix64, _ actual: UFix64): Bool {
    // return true if expected is within DEFAULT_UFIX_VARIANCE of actual, false otherwise and protect for underflow`
    let diff = Fix64(expected) - Fix64(actual)
    // take the absolute value of the difference without relying on .abs()
    let absDiff: UFix64 = diff < 0.0 ? UFix64(-1.0 * diff) : UFix64(diff)
    return absDiff <= DEFAULT_UFIX_VARIANCE
}

access(all) fun ufix128EqualWithinVariance(_ expected: UFix128, _ actual: UFix128): Bool {
    let absDiff: UFix128 = expected >= actual ? expected - actual : actual - expected
    return absDiff <= DEFAULT_UFIX128_VARIANCE
}

/* --- Balance & Timestamp Helpers --- */

access(all)
fun getBlockTimestamp(): UFix64 {
    let res = _executeScript("../scripts/flow-credit-market/get_block_timestamp.cdc", [])
    Test.expect(res, Test.beSucceeded())
    return res.returnValue as! UFix64
}

access(all)
fun getDebitBalanceForType(details: FlowCreditMarket.PositionDetails, vaultType: Type): UFix64 {
    for balance in details.balances {
        if balance.vaultType == vaultType && balance.direction == FlowCreditMarket.BalanceDirection.Debit {
            return balance.balance
        }
    }
    return 0.0
}

access(all)
fun getCreditBalanceForType(details: FlowCreditMarket.PositionDetails, vaultType: Type): UFix64 {
    for balance in details.balances {
        if balance.vaultType == vaultType && balance.direction == FlowCreditMarket.BalanceDirection.Credit {
            return balance.balance
        }
    }
    return 0.0
}
