import Test
import "TidalProtocol"
import "FungibleToken"
import "ViewResolver"

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
    
    // TODO: Set up FlowToken vault in the account
    // This will be needed when we fully integrate with FlowToken
    
    return account
}

// Helper to get the deployed TidalProtocol address
access(all) fun getTidalProtocolAddress(): Address {
    return 0x0000000000000007
}

// ADDED: Function to mint FLOW tokens from the service account
// This replaces createTestVault() to use real FLOW tokens
access(all) fun mintFlow(_ amount: UFix64): @MockVault {
    // Get the service account which has minting capability
    let serviceAccount = Test.serviceAccount()
    
    // TODO: Implement proper FLOW minting from service account
    // For now, we'll use MockVault for testing
    panic("Real FLOW minting not implemented yet - use createTestVault for now")
}

// CHANGE: Create a mock vault for testing since we can't create FlowToken vaults directly
access(all) resource MockVault: FungibleToken.Vault {
    access(all) var balance: UFix64
    
    access(all) fun deposit(from: @{FungibleToken.Vault}) {
        let vault <- from as! @MockVault
        self.balance = self.balance + vault.balance
        vault.balance = 0.0
        destroy vault
    }
    
    access(FungibleToken.Withdraw) fun withdraw(amount: UFix64): @{FungibleToken.Vault} {
        self.balance = self.balance - amount
        return <- create MockVault(balance: amount)
    }
    
    access(all) view fun isAvailableToWithdraw(amount: UFix64): Bool {
        return self.balance >= amount
    }
    
    access(all) fun createEmptyVault(): @{FungibleToken.Vault} {
        return <- create MockVault(balance: 0.0)
    }
    
    // ViewResolver conformance
    access(all) view fun getViews(): [Type] {
        return []
    }
    
    access(all) fun resolveView(_ view: Type): AnyStruct? {
        return nil
    }
    
    init(balance: UFix64) {
        self.balance = balance
    }
}

// CHANGE: Helper to create test vaults
access(all) fun createTestVault(balance: UFix64): @MockVault {
    return <- create MockVault(balance: balance)
}

// CHANGE: Helper to create test pools with MockVault as default token
access(all) fun createTestPool(defaultTokenThreshold: UFix64): @TidalProtocol.Pool {
    return <- TidalProtocol.createPool(
        defaultToken: Type<@MockVault>(),
        defaultTokenThreshold: defaultTokenThreshold
    )
}

// CHANGE: Helper to create test pools with initial balance
access(all) fun createTestPoolWithBalance(defaultTokenThreshold: UFix64, initialBalance: UFix64): @TidalProtocol.Pool {
    var pool <- createTestPool(defaultTokenThreshold: defaultTokenThreshold)
    let poolRef = &pool as auth(TidalProtocol.EPosition) &TidalProtocol.Pool
    let pid = poolRef.createPosition()
    let vault <- createTestVault(balance: initialBalance)
    poolRef.deposit(pid: pid, funds: <- vault)
    return <- pool
} 