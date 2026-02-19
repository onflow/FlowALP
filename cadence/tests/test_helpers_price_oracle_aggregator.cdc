import Test
import "DeFiActions"
import "FlowPriceOracleAggregatorv1"
import "MultiMockOracle"

access(all) struct CreateAggregatorInfo {
    access(all) let aggregatorStorageID: UInt64
    access(all) let mockOracleStorageIDs: [UInt64]

    init(aggregatorStorageID: UInt64, mockOracleStorageIDs: [UInt64]) {
        self.aggregatorStorageID = aggregatorStorageID
        self.mockOracleStorageIDs = mockOracleStorageIDs
    }
}

access(all) fun createAggregator(
    ofToken: Type,
    oracleCount: Int,
    maxSpread: UFix64,
    baseTolerance: UFix64,
    driftExpansionRate: UFix64,
    priceHistorySize: Int,
    priceHistoryInterval: UFix64,
    maxPriceHistoryAge: UFix64,
    unitOfAccount: Type,
): CreateAggregatorInfo {
    let res = _executeTransaction(
        "./transactions/price-oracle-aggregator/create.cdc",
        [ofToken, oracleCount, maxSpread, baseTolerance, driftExpansionRate, priceHistorySize, priceHistoryInterval, maxPriceHistoryAge, unitOfAccount],
        []
    )
    Test.expect(res, Test.beSucceeded())
    let aggregatorCreatedEvents = Test.eventsOfType(Type<FlowPriceOracleAggregatorv1.StorageCreated>())
    let aggregatorCreatedData = aggregatorCreatedEvents[aggregatorCreatedEvents.length - 1] as! FlowPriceOracleAggregatorv1.StorageCreated
    let oracleCreatedEvents = Test.eventsOfType(Type<MultiMockOracle.OracleCreated>())
    let oracleIDs: [UInt64] = []
    var i = oracleCreatedEvents.length - oracleCount
    while i < oracleCreatedEvents.length {
        let oracleCreatedData = oracleCreatedEvents[i] as! MultiMockOracle.OracleCreated
        oracleIDs.append(oracleCreatedData.storageID)
        i = i + 1
    }
    return CreateAggregatorInfo(
        aggregatorStorageID: aggregatorCreatedData.storageID,
        mockOracleStorageIDs: oracleIDs
    )
}

access(all) fun createAggregatorWithCron(
    signer: Test.TestAccount,
    ofToken: Type,
    oracleCount: Int,
    maxSpread: UFix64,
    baseTolerance: UFix64,
    driftExpansionRate: UFix64,
    priceHistorySize: Int,
    priceHistoryInterval: UFix64,
    maxPriceHistoryAge: UFix64,
    unitOfAccount: Type,
    cronExpression: String,
    cronHandlerStoragePath: StoragePath,
    keeperExecutionEffort: UInt64,
    executorExecutionEffort: UInt64,
    aggregatorCronHandlerStoragePath: StoragePath
): CreateAggregatorInfo {
    let res = _executeTransaction(
        "./transactions/price-oracle-aggregator/create_with_cron.cdc",
        [ofToken, oracleCount, maxSpread, baseTolerance, driftExpansionRate, priceHistorySize, priceHistoryInterval, maxPriceHistoryAge, unitOfAccount, cronExpression, cronHandlerStoragePath, keeperExecutionEffort, executorExecutionEffort, aggregatorCronHandlerStoragePath],
        [signer]
    )
    Test.expect(res, Test.beSucceeded())
    let aggregatorCreatedEvents = Test.eventsOfType(Type<FlowPriceOracleAggregatorv1.StorageCreated>())
    let aggregatorCreatedData = aggregatorCreatedEvents[aggregatorCreatedEvents.length - 1] as! FlowPriceOracleAggregatorv1.StorageCreated
    let oracleCreatedEvents = Test.eventsOfType(Type<MultiMockOracle.OracleCreated>())
    let oracleIDs: [UInt64] = []
    var i = oracleCreatedEvents.length - oracleCount
    while i < oracleCreatedEvents.length {
        let oracleCreatedData = oracleCreatedEvents[i] as! MultiMockOracle.OracleCreated
        oracleIDs.append(oracleCreatedData.storageID)
        i = i + 1
    }
    return CreateAggregatorInfo(
        aggregatorStorageID: aggregatorCreatedData.storageID,
        mockOracleStorageIDs: oracleIDs
    )
}

// speed improvement by not executing individual transactions
access(all) fun setMultiMockOraclePriceTx(
    storageID: UInt64,
    forToken: Type,
    price: UFix64?,
): Test.Transaction {
    return getTransaction(
        "./transactions/multi-mock-oracle/set_price.cdc",
        [storageID, forToken, price],
        []
    )
}

access(all) fun setMultiMockOraclePrice(
    storageID: UInt64,
    forToken: Type,
    price: UFix64?,
) {
    let res = _executeTransaction(
        "./transactions/multi-mock-oracle/set_price.cdc",
        [storageID, forToken, price],
        []
    )
    Test.expect(res, Test.beSucceeded())
}

access(all) fun oracleAggregatorPrice(
    storageID: UInt64,
    ofToken: Type,
): UFix64? {
    // execute transaction to emit events
    let res = _executeTransaction(
        "./transactions/price-oracle-aggregator/price.cdc",
        [storageID, ofToken],
        []
    )
    Test.expect(res, Test.beSucceeded())
    // execute script to get price
    let res2 = _executeScript(
        "./scripts/price-oracle-aggregator/price.cdc",
        [storageID, ofToken]
    )
    Test.expect(res2, Test.beSucceeded())
    return res2.returnValue as! UFix64?
}

access(all) fun oracleAggregatorPriceTx(
    storageID: UInt64,
    ofToken: Type,
): Test.Transaction {
    return getTransaction(
        "./transactions/price-oracle-aggregator/price.cdc",
        [storageID, ofToken],
        []
    )
}

access(all) fun oracleAggregatorAssertPriceTx(
    storageID: UInt64,
    ofToken: Type,
    price: UFix64?,
): Test.Transaction {
    return getTransaction(
        "./transactions/price-oracle-aggregator/assert_price.cdc",
        [storageID, ofToken, price],
        []
    )
}

access(all) fun oracleAggregatorPriceHistory(
    storageID: UInt64,
): [FlowPriceOracleAggregatorv1.PriceHistoryEntry] {
    let res = _executeScript(
        "./scripts/price-oracle-aggregator/history.cdc",
        [storageID]
    )
    Test.expect(res, Test.beSucceeded())
    return res.returnValue as! [FlowPriceOracleAggregatorv1.PriceHistoryEntry]
}

// --- Helper Functions ---

access(self) fun getTransaction(_ path: String, _ args: [AnyStruct], _ signers: [Test.TestAccount]): Test.Transaction {
    let authorizers: [Address] = []
    for signer in signers {
        authorizers.append(signer.address)
    }
    return Test.Transaction(
        code: Test.readFile(path),
        authorizers: authorizers,
        signers: signers,
        arguments: args,
    )
}

access(self) fun _executeTransaction(_ path: String, _ args: [AnyStruct], _ signers: [Test.TestAccount]): Test.TransactionResult {
    let authorizers: [Address] = []
    for signer in signers {
        authorizers.append(signer.address)
    }
    let txn = Test.Transaction(
        code: Test.readFile(path),
        authorizers: authorizers,
        signers: signers,
        arguments: args,
    )
    return Test.executeTransaction(txn)
}

access(self) fun _executeScript(_ path: String, _ args: [AnyStruct]): Test.ScriptResult {
    return Test.executeScript(Test.readFile(path), args)
}