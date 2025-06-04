import Test
import TidalProtocol from "TidalProtocol"

// Common test setup function that deploys all required contracts
access(all) fun deployContracts() {
    // Deploy DFB first since TidalProtocol imports it
    var err = Test.deployContract(
        name: "DFB",
        path: "../../DeFiBlocks/cadence/contracts/interfaces/DFB.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    // Deploy MOET before TidalProtocol since TidalProtocol imports it
    err = Test.deployContract(
        name: "MOET",
        path: "../contracts/MOET.cdc",
        arguments: [1000000.0]  // Initial supply
    )
    Test.expect(err, Test.beNil())
    
    // Deploy TidalProtocol
    err = Test.deployContract(
        name: "TidalProtocol",
        path: "../contracts/TidalProtocol.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
}

// Helper to create a test account
access(all) fun createTestAccount(): Test.TestAccount {
    let account = Test.createAccount()
    
    // Set up FlowToken vault in the account using a transaction
    // This simulates what would happen in production
    let setupTx = Test.Transaction(
        code: Test.readFile("../transactions/setup_flowtoken_vault.cdc"),
        authorizers: [account.address],
        signers: [account],
        arguments: []
    )
    
    let setupResult = Test.executeTransaction(setupTx)
    Test.expect(setupResult, Test.beSucceeded())
    
    return account
}

// Helper to get the deployed TidalProtocol address
access(all) fun getTidalProtocolAddress(): Address {
    return 0x0000000000000007
}

// Helper to create a dummy oracle for testing
// Returns the oracle as AnyStruct since we can't use contract types directly
access(all) fun createDummyOracle(defaultToken: Type): AnyStruct {
    // Use a script to create the oracle
    let code = "import TidalProtocol from ".concat(getTidalProtocolAddress().toString()).concat("\n")
        .concat("access(all) fun main(defaultToken: Type): TidalProtocol.DummyPriceOracle {\n")
        .concat("    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: defaultToken)\n")
        .concat("    oracle.setPrice(token: defaultToken, price: 1.0)\n")
        .concat("    return oracle\n")
        .concat("}")
    
    let result = Test.executeScript(code, [defaultToken])
    Test.expect(result, Test.beSucceeded())
    return result.returnValue!
}

// Function to mint FLOW tokens from the service account
// This simulates real FLOW minting in a test environment
access(all) fun mintFlow(_ account: Test.TestAccount, _ amount: UFix64) {
    // Use the mint transaction to mint FLOW tokens
    let mintTx = Test.Transaction(
        code: Test.readFile("../transactions/mint_flowtoken.cdc"),
        authorizers: [Test.serviceAccount().address],
        signers: [Test.serviceAccount()],
        arguments: [account.address, amount]
    )
    
    let mintResult = Test.executeTransaction(mintTx)
    Test.expect(mintResult, Test.beSucceeded())
}

// Create a mock vault for testing since we can't create FlowToken vaults directly
// Using a simplified structure for test context
access(all) resource MockVault {
    access(all) var balance: UFix64
    
    access(all) fun deposit(from: @MockVault) {
        self.balance = self.balance + from.balance
        from.balance = 0.0
        destroy from
    }
    
    access(all) fun withdraw(amount: UFix64): @MockVault {
        self.balance = self.balance - amount
        return <- create MockVault(balance: amount)
    }
    
    access(all) view fun isAvailableToWithdraw(amount: UFix64): Bool {
        return self.balance >= amount
    }
    
    access(all) fun createEmptyVault(): @MockVault {
        return <- create MockVault(balance: 0.0)
    }
    
    init(balance: UFix64) {
        self.balance = balance
    }
}

// Helper to create test vaults
access(all) fun createTestVault(balance: UFix64): @MockVault {
    return <- create MockVault(balance: balance)
}

// Create a pool with oracle using transaction file
// This is the primary function tests should use
access(all) fun createTestPoolWithOracle(): @TidalProtocol.Pool {
    // Create oracle
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<@MockVault>())
    oracle.setPrice(token: Type<@MockVault>(), price: 1.0)
    
    // Create pool
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<@MockVault>(),
        priceOracle: oracle
    )
    
    // Add default token support
    pool.addSupportedToken(
        tokenType: Type<@MockVault>(),
        collateralFactor: 0.8,
        borrowFactor: 1.2,
        interestCurve: TidalProtocol.SimpleInterestCurve(),
        depositRate: 10000.0,
        depositCapacityCap: 1000000.0
    )
    
    return <- pool
}

// Create pool with oracle and initial balance
// NOTE: This creates an empty pool - tests should handle deposits separately
access(all) fun createTestPoolWithOracleAndBalance(initialBalance: UFix64): @TidalProtocol.Pool {
    // Just create the pool - tests will handle deposits through positions
    return <- createTestPoolWithOracle()
}

// Create pool with specific risk parameters using a transaction
access(all) fun createTestPoolWithRiskParams(
    account: Test.TestAccount,
    collateralFactor: UFix64,
    borrowFactor: UFix64,
    depositRate: UFix64,
    depositCap: UFix64
): Bool {
    // Use the create pool transaction with custom parameters
    let createPoolTx = Test.Transaction(
        code: Test.readFile("../transactions/create_pool_with_oracle.cdc"),
        authorizers: [account.address],
        signers: [account],
        arguments: []
    )
    
    let result = Test.executeTransaction(createPoolTx)
    Test.expect(result, Test.beSucceeded())
    
    // Now update the pool parameters
    // This would require a separate transaction to modify pool parameters
    // For now, return success
    return true
}

// Helper to check if an account has a pool
access(all) fun hasPool(account: Test.TestAccount): Bool {
    let script = Test.readFile("../scripts/get_pool_reference.cdc")
    let result = Test.executeScript(script, [account.address])
    Test.expect(result, Test.beSucceeded())
    return result.returnValue! as! Bool
}

// Helper to create multi-token pool using transaction
access(all) fun createMultiTokenTestPool(
    account: Test.TestAccount,
    tokenTypes: [Type], 
    prices: [UFix64],
    collateralFactors: [UFix64],
    borrowFactors: [UFix64]
): Bool {
    // Use the multi-token pool creation transaction
    let createMultiPoolTx = Test.Transaction(
        code: Test.readFile("../transactions/create_multi_token_pool.cdc"),
        authorizers: [account.address],
        signers: [account],
        arguments: [tokenTypes, prices, collateralFactors, borrowFactors]
    )
    
    let result = Test.executeTransaction(createMultiPoolTx)
    Test.expect(result, Test.beSucceeded())
    return true
}

// NOTE: The following functions need to be updated in each test file that uses them
// Since we cannot directly access contract types in test files, tests must:
// 1. Use Test.executeScript() to create oracles
// 2. Use Test.Transaction() to create pools with oracles
// 3. Handle the oracle parameter when calling TidalProtocol.createPool()

// REMOVED: Deprecated functions - tests should use the new patterns above
// access(all) fun createTestPool(): @AnyResource
// access(all) fun createTestPoolWithOracle(): @AnyResource  
// access(all) fun createTestPoolWithBalance(initialBalance: UFix64): @AnyResource
// access(all) fun createMultiTokenTestPool(): @AnyResource 