# Cadence Testing Best Practices

Based on patterns from [Flow EVM Bridge tests](https://github.com/onflow/flow-evm-bridge/tree/main/cadence/tests) and other Flow projects.

## 1. Test File Organization

### Directory Structure
```
cadence/tests/
├── test_helpers.cdc          # Shared test utilities
├── setup_tests.cdc           # Common setup functions
├── unit/                     # Unit tests for individual components
│   ├── ComponentA_test.cdc
│   └── ComponentB_test.cdc
├── integration/              # Integration tests
│   └── flow_integration_test.cdc
└── fixtures/                 # Test data and mock contracts
    └── mock_contracts.cdc
```

## 2. Test File Structure Pattern

```cadence
import Test
import BlockchainHelpers
import "ContractName"

// Test helper functions at the top
access(all) fun setupTest(): @TestResources {
    // Setup code
}

// Main setup function
access(all) fun setup() {
    let err = Test.deployContract(
        name: "ContractName",
        path: "../contracts/ContractName.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
}

// Individual test functions
access(all) fun testFeatureName() {
    // Test implementation
}

// Cleanup if needed
access(all) fun tearDown() {
    // Cleanup code
}
```

## 3. Common Test Patterns

### 3.1 Contract Deployment
```cadence
// Deploy with arguments
let err = Test.deployContract(
    name: "MyContract",
    path: "../contracts/MyContract.cdc",
    arguments: [arg1, arg2]
)
Test.expect(err, Test.beNil())

// Deploy multiple contracts
let contracts = ["ContractA", "ContractB", "ContractC"]
for contract in contracts {
    let err = Test.deployContract(
        name: contract,
        path: "../contracts/".concat(contract).concat(".cdc"),
        arguments: []
    )
    Test.expect(err, Test.beNil())
}
```

### 3.2 Account Management
```cadence
// Create test accounts
let alice = Test.createAccount()
let bob = Test.createAccount()

// Fund accounts
let fundingResult = Test.mintFlow(to: alice, amount: 1000.0)
Test.expect(fundingResult, Test.beSucceeded())

// Get account addresses
let aliceAddress = alice.address
let bobAddress = bob.address
```

### 3.3 Transaction Testing
```cadence
// Execute transaction
let txResult = Test.executeTransaction(
    "../transactions/my_transaction.cdc",
    [arg1, arg2],
    alice
)
Test.expect(txResult, Test.beSucceeded())

// Test transaction failure
let failingTx = Test.executeTransaction(
    "../transactions/failing_transaction.cdc",
    [invalidArg],
    bob
)
Test.expect(failingTx, Test.beFailed())
Test.assertError(failingTx, errorMessage: "Expected error message")
```

### 3.4 Script Execution
```cadence
// Execute script and check result
let scriptResult = Test.executeScript(
    "../scripts/get_balance.cdc",
    [accountAddress]
)
Test.expect(scriptResult, Test.beSucceeded())

let balance = scriptResult.returnValue! as! UFix64
Test.assertEqual(100.0, balance)
```

### 3.5 Event Testing
```cadence
// Test event emission
let events = Test.eventsOfType(Type<MyContract.MyEvent>())
Test.expect(events.length, Test.beGreaterThan(0))

let event = events[0] as! MyContract.MyEvent
Test.assertEqual(expectedValue, event.field)
```

## 4. Advanced Testing Patterns

### 4.1 Time Manipulation
```cadence
// Advance blockchain time
Test.moveTime(by: 86400.0) // Advance by 1 day

// Set specific block height
Test.moveToBlockHeight(1000)
```

### 4.2 Error Handling Without Test.expectFailure
```cadence
// Pattern 1: Using Test.executeTransaction with error checking
let result = Test.executeTransaction(
    "../transactions/will_fail.cdc",
    [args],
    signer
)
Test.expect(result, Test.beFailed())
Test.assertError(result, errorMessage: "Expected error substring")

// Pattern 2: Using scripts to check state
let canWithdraw = Test.executeScript(
    "pub fun main(amount: UFix64): Bool { 
        // Check if withdrawal would succeed
        return amount <= availableBalance 
    }",
    [withdrawAmount]
).returnValue! as! Bool
Test.assertEqual(false, canWithdraw)
```

### 4.3 Resource Management
```cadence
// Create and manage resources in tests
access(all) fun testResourceCreation() {
    let testAccount = Test.createAccount()
    
    // Create resource via transaction
    let createResult = Test.executeTransaction(
        "../transactions/create_resource.cdc",
        [],
        testAccount
    )
    Test.expect(createResult, Test.beSucceeded())
    
    // Verify resource exists
    let hasResource = Test.executeScript(
        "../scripts/check_resource.cdc",
        [testAccount.address]
    ).returnValue! as! Bool
    Test.assertEqual(true, hasResource)
}
```

### 4.4 Complex State Testing
```cadence
// Test complex state changes
access(all) fun testComplexStateChange() {
    // Setup initial state
    let setupResult = executeSetupTransactions()
    Test.expect(setupResult, Test.beSucceeded())
    
    // Perform action
    let actionResult = Test.executeTransaction(
        "../transactions/complex_action.cdc",
        [param1, param2],
        signer
    )
    Test.expect(actionResult, Test.beSucceeded())
    
    // Verify multiple state changes
    let finalState = Test.executeScript(
        "../scripts/get_state.cdc",
        []
    ).returnValue! as! {String: AnyStruct}
    
    Test.assertEqual(expectedValue1, finalState["field1"])
    Test.assertEqual(expectedValue2, finalState["field2"])
}
```

## 5. Test Helpers and Utilities

### 5.1 Common Test Helper Functions
```cadence
// Reusable setup function
access(all) fun setupTestEnvironment(): TestEnvironment {
    let admin = Test.createAccount()
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    
    // Deploy contracts
    deployAllContracts()
    
    // Initialize
    initializeContracts(admin: admin)
    
    return TestEnvironment(
        admin: admin,
        user1: user1,
        user2: user2
    )
}

// Batch operations
access(all) fun mintTokensToMultipleAccounts(
    accounts: [Test.Account],
    amount: UFix64
) {
    for account in accounts {
        let mintResult = Test.executeTransaction(
            "../transactions/mint_tokens.cdc",
            [account.address, amount],
            admin
        )
        Test.expect(mintResult, Test.beSucceeded())
    }
}
```

### 5.2 Custom Assertions
```cadence
// Custom assertion functions
access(all) fun assertBalanceEquals(
    account: Test.Account,
    expectedBalance: UFix64,
    message: String
) {
    let balance = getBalance(account: account)
    Test.assertEqual(
        expectedBalance,
        balance,
        message: message.concat(" - Expected: ")
            .concat(expectedBalance.toString())
            .concat(", Got: ")
            .concat(balance.toString())
    )
}

// Range assertions
access(all) fun assertInRange(
    value: UFix64,
    min: UFix64,
    max: UFix64,
    message: String
) {
    Test.assert(
        value >= min && value <= max,
        message: message
    )
}
```

## 6. Best Practices Summary

1. **Use Test.executeTransaction instead of Test.expectFailure** when possible
2. **Create helper functions** for common operations
3. **Use descriptive test names** that explain what is being tested
4. **Group related tests** in the same file
5. **Clean up resources** after tests when necessary
6. **Use scripts** to verify state instead of relying on transaction success
7. **Test both success and failure cases**
8. **Use meaningful assertion messages** that help debug failures
9. **Avoid hardcoded values** - use constants or helper functions
10. **Test edge cases** and boundary conditions

## 7. Common Pitfalls to Avoid

1. **Don't use Test.expectFailure** - it has known issues in the current framework
2. **Don't assume transaction order** - each test should be independent
3. **Don't forget to check events** when they're part of the contract behavior
4. **Don't ignore precision issues** with UFix64 calculations
5. **Don't test implementation details** - focus on behavior

## 8. Example Test Suite Structure

```cadence
import Test
import BlockchainHelpers
import "MyContract"

// Constants
let INITIAL_SUPPLY: UFix64 = 1000000.0
let DECIMALS: UInt8 = 8

// Helper structures
access(all) struct TestAccounts {
    access(all) let admin: Test.Account
    access(all) let alice: Test.Account
    access(all) let bob: Test.Account
    
    init() {
        self.admin = Test.createAccount()
        self.alice = Test.createAccount()
        self.bob = Test.createAccount()
    }
}

// Setup
access(all) fun setup() {
    // Deploy contract
    let err = Test.deployContract(
        name: "MyContract",
        path: "../contracts/MyContract.cdc",
        arguments: [INITIAL_SUPPLY, DECIMALS]
    )
    Test.expect(err, Test.beNil())
}

// Helper functions
access(all) fun setupAccounts(): TestAccounts {
    return TestAccounts()
}

// Tests
access(all) fun testInitialization() {
    let supply = Test.executeScript(
        "../scripts/get_total_supply.cdc",
        []
    ).returnValue! as! UFix64
    
    Test.assertEqual(INITIAL_SUPPLY, supply)
}

access(all) fun testTransfer() {
    let accounts = setupAccounts()
    
    // Setup: Give Alice some tokens
    let mintResult = Test.executeTransaction(
        "../transactions/mint.cdc",
        [accounts.alice.address, 100.0],
        accounts.admin
    )
    Test.expect(mintResult, Test.beSucceeded())
    
    // Action: Transfer from Alice to Bob
    let transferResult = Test.executeTransaction(
        "../transactions/transfer.cdc",
        [accounts.bob.address, 50.0],
        accounts.alice
    )
    Test.expect(transferResult, Test.beSucceeded())
    
    // Verify: Check balances
    let aliceBalance = getBalance(accounts.alice)
    let bobBalance = getBalance(accounts.bob)
    
    Test.assertEqual(50.0, aliceBalance)
    Test.assertEqual(50.0, bobBalance)
}

// Utility functions
access(all) fun getBalance(account: Test.Account): UFix64 {
    return Test.executeScript(
        "../scripts/get_balance.cdc",
        [account.address]
    ).returnValue! as! UFix64
}
```

This guide provides a comprehensive foundation for writing robust Cadence tests based on patterns from successful Flow projects. 