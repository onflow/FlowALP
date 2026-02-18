import Test

access(all) fun createPriceOracleRouter(
    unitOfAccount: Type,
    createRouterInfo: [{String: AnyStruct}],
    expectSucceeded: Bool
) {
    let res = _executeTransaction(
        "./transactions/price-oracle-router/create.cdc",
        [unitOfAccount, createRouterInfo],
        []
    )
    Test.expect(res, expectSucceeded ? Test.beSucceeded() : Test.beFailed())
}

// need this because can't define struct here to pass to transaction
access(all) fun createPriceOracleRouterInfo(
    unitOfAccount: Type,
    oracleOfToken: Type,
    prices: UFix64?
): {String: AnyStruct} {
    return {
        "unitOfAccount": unitOfAccount,
        "oracleOfToken": oracleOfToken,
        "price": prices
    }
}

access(all) fun priceOracleRouterPrice(ofToken: Type): UFix64? {
    let res = _executeScript(
        "./scripts/price-oracle-router/price.cdc",
        [ofToken],
    )
    Test.expect(res, Test.beSucceeded())
    return res.returnValue as! UFix64?
}

// --- Helper Functions ---

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