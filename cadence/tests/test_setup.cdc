import Test

// Deploy all necessary contracts for testing
access(all) fun deployAll() {
    // The standard contracts are already available in the testing framework at these addresses:
    // FungibleToken: 0x0000000000000002
    // FlowToken: 0x0000000000000003
    // ViewResolver, MetadataViews, NonFungibleToken: 0x0000000000000001
    // Burner is included within FungibleToken in Cadence 1.0
    
    // Deploy DFB
    var err = Test.deployContract(
        name: "DFB",
        path: "../../DeFiBlocks/cadence/contracts/interfaces/DFB.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    // Deploy MOET
    err = Test.deployContract(
        name: "MOET",
        path: "../contracts/MOET.cdc",
        arguments: [1000000.0]
    )
    Test.expect(err, Test.beNil())
    
    // Deploy TidalProtocol
    err = Test.deployContract(
        name: "TidalProtocol",
        path: "../contracts/TidalProtocol.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    // Deploy TidalPoolGovernance
    err = Test.deployContract(
        name: "TidalPoolGovernance",
        path: "../contracts/TidalPoolGovernance.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
}

// Helper function to get FlowToken from service account
access(all) fun getFlowToken(blockchain: Test.Blockchain, account: Test.TestAccount, amount: UFix64) {
    // Use the transaction file
    let tx = Test.Transaction(
        code: Test.readFile("../transactions/mint_flowtoken.cdc"),
        authorizers: [blockchain.serviceAccount().address],
        signers: [blockchain.serviceAccount()],
        arguments: [account.address, amount]
    )
    let result = blockchain.executeTransaction(tx)
    Test.expect(result, Test.beSucceeded())
}

// Helper to setup FlowToken vault for an account
access(all) fun setupFlowTokenVault(blockchain: Test.Blockchain, account: Test.TestAccount) {
    // Use the transaction file
    let tx = Test.Transaction(
        code: Test.readFile("../transactions/setup_flowtoken_vault.cdc"),
        authorizers: [account.address],
        signers: [account],
        arguments: []
    )
    let result = blockchain.executeTransaction(tx)
    Test.expect(result, Test.beSucceeded())
}

// Create a TidalProtocol pool with FlowToken as the default token
access(all) fun createFlowTokenPool(defaultTokenThreshold: UFix64): @TidalProtocol.Pool {
    return <- TidalProtocol.createPool(
        defaultToken: Type<@FlowToken.Vault>(),
        defaultTokenThreshold: defaultTokenThreshold
    )
}

// Get FlowToken balance for an account
access(all) fun getFlowTokenBalance(blockchain: Test.Blockchain, account: Test.TestAccount): UFix64 {
    let result = blockchain.executeScript(
        Test.readFile("../scripts/get_flowtoken_balance.cdc"),
        [account.address]
    )
    Test.expect(result, Test.beSucceeded())
    return result.returnValue! as! UFix64
}

// Helper to deposit FlowToken into a pool position
access(all) fun depositFlowToken(blockchain: Test.Blockchain, account: Test.TestAccount, positionID: UInt64, amount: UFix64) {
    let tx = Test.Transaction(
        code: Test.readFile("../transactions/deposit_flowtoken.cdc"),
        authorizers: [account.address],
        signers: [account],
        arguments: [positionID, amount]
    )
    let result = blockchain.executeTransaction(tx)
    Test.expect(result, Test.beSucceeded())
}

// Helper to borrow FlowToken from a pool position
access(all) fun borrowFlowToken(blockchain: Test.Blockchain, account: Test.TestAccount, positionID: UInt64, amount: UFix64) {
    let tx = Test.Transaction(
        code: Test.readFile("../transactions/borrow_flowtoken.cdc"),
        authorizers: [account.address],
        signers: [account],
        arguments: [positionID, amount]
    )
    let result = blockchain.executeTransaction(tx)
    Test.expect(result, Test.beSucceeded())
}

// Create and store a FlowToken pool in an account
access(all) fun createAndStoreFlowTokenPool(blockchain: Test.Blockchain, account: Test.TestAccount, defaultTokenThreshold: UFix64) {
    let tx = Test.Transaction(
        code: Test.readFile("../transactions/create_and_store_pool.cdc"),
        authorizers: [account.address],
        signers: [account],
        arguments: [defaultTokenThreshold]
    )
    let result = blockchain.executeTransaction(tx)
    Test.expect(result, Test.beSucceeded())
} 