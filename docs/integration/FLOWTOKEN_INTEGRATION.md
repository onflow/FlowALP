# FlowToken Integration Documentation

## Overview
This document summarizes the complete FlowToken integration into TidalProtocol, including all learnings, implementation details, and best practices discovered during the integration process.

## Key Learnings

### 1. FlowToken in Cadence Testing Framework
- **FlowToken is pre-deployed** at address `0x0000000000000003` in the test environment
- **FungibleToken** is at address `0x0000000000000002`
- **Standard contracts** (MetadataViews, ViewResolver, etc.) are at `0x0000000000000001`
- The **service account** has access to `FlowToken.Minter` for minting tokens in tests

### 2. Burner Changes in Cadence 1.0
- **Burner is no longer a separate import** - it's now part of FungibleToken
- Removed `import "Burner"` from TidalProtocol.cdc
- This change is part of Cadence 1.0 updates

### 3. Critical: Avoiding Test Hangs
- **Inline transaction code causes tests to hang indefinitely**
- Never use inline code like:
  ```cadence
  let code = """
  transaction { ... }
  """
  ```
- Always create separate `.cdc` files for transactions and scripts
- Use `Test.readFile()` to load transaction/script code

## Implementation Details

### Files Created

#### 1. Transaction Files
- `cadence/transactions/setup_flowtoken_vault.cdc` - Sets up FlowToken vault for an account
- `cadence/transactions/mint_flowtoken.cdc` - Mints FlowToken from service account to a recipient
- `cadence/transactions/deposit_flowtoken.cdc` - Deposits FlowToken into a pool position
- `cadence/transactions/borrow_flowtoken.cdc` - Borrows FlowToken from a pool position
- `cadence/transactions/create_and_store_pool.cdc` - Creates a pool with FlowToken as default token
- `cadence/transactions/setup_moet_vault.cdc` - Sets up MOET vault for an account

#### 2. Script Files
- `cadence/scripts/get_flowtoken_balance.cdc` - Retrieves FlowToken balance for an address

#### 3. Test Files
- `cadence/tests/flowtoken_integration_test.cdc` - Comprehensive FlowToken integration tests
- `cadence/tests/test_setup.cdc` - Updated with FlowToken helper functions

### Test Helper Functions

```cadence
// Get FlowToken from service account
access(all) fun getFlowToken(blockchain: Test.Blockchain, account: Test.TestAccount, amount: UFix64)

// Setup FlowToken vault for an account
access(all) fun setupFlowTokenVault(blockchain: Test.Blockchain, account: Test.TestAccount)

// Get FlowToken balance
access(all) fun getFlowTokenBalance(blockchain: Test.Blockchain, account: Test.TestAccount): UFix64

// Deposit FlowToken into pool position
access(all) fun depositFlowToken(blockchain: Test.Blockchain, account: Test.TestAccount, positionID: UInt64, amount: UFix64)

// Borrow FlowToken from pool position
access(all) fun borrowFlowToken(blockchain: Test.Blockchain, account: Test.TestAccount, positionID: UInt64, amount: UFix64)

// Create and store FlowToken pool
access(all) fun createAndStoreFlowTokenPool(blockchain: Test.Blockchain, account: Test.TestAccount, defaultTokenThreshold: UFix64)
```

## Testing Patterns

### 1. Correct Test Structure
```cadence
import Test

// NO blockchain instance creation - Test methods are called directly
access(all) fun setup() {
    // Deploy contracts
    var err = Test.deployContract(...)
    Test.expect(err, Test.beNil())
}

access(all) fun testExample() {
    // Tests use Test.TestAccount, not Test.Account
    // No inline transaction code
    let tx = Test.Transaction(
        code: Test.readFile("../transactions/example.cdc"),
        authorizers: [account.address],
        signers: [account],
        arguments: []
    )
}
```

### 2. Avoiding Common Pitfalls
- ❌ Don't use `Test.Account` - use `Test.TestAccount`
- ❌ Don't use `Test.newEmulatorBlockchain()` - not available in current version
- ❌ Don't use `Test.createTransactionFromPath()` - use `Test.Transaction` with `Test.readFile()`
- ❌ Don't use `Test.expectFailure()` - handle errors differently
- ❌ Don't use inline transaction/script code - always use separate files

### 3. FlowToken vs MockVault
- **MockVault**: Used in basic unit tests for simplicity
- **FlowToken**: Used in integration tests for realistic scenarios
- Both patterns coexist - tests can choose appropriate token type

## Pool Creation with FlowToken

```cadence
// Create a pool with FlowToken as the default token
let pool <- TidalProtocol.createPool(
    defaultToken: Type<@FlowToken.Vault>(),
    defaultTokenThreshold: 0.8
)

// Add MOET as a secondary token
poolRef.addSupportedToken(
    tokenType: Type<@MOET.Vault>(),
    exchangeRate: 1.0,  // 1 MOET = 1 FLOW
    liquidationThreshold: 0.75,
    interestCurve: TidalProtocol.SimpleInterestCurve()
)
```

## Contract Address Configuration

Updated `flow.json` to include FlowToken testing addresses:
```json
"FlowToken": {
    "aliases": {
        "emulator": "0x0ae53cb6e3f42a79",
        "testnet": "0x7e60df042a9c0868",
        "mainnet": "0x1654653399040a61",
        "testing": "0x0000000000000003"
    }
}
```

## Test Results
- **Total Tests**: 54 (all passing)
- **Code Coverage**: 88.9%
- **FlowToken Tests**: 3 (all passing)
- **MOET/Governance Tests**: Unchanged and working

## Future Considerations

1. **Service Account Minting**: In production, FlowToken minting won't be available. Tests should account for this.

2. **Transaction Fees**: Real FlowToken transactions have fees - tests currently don't simulate this.

3. **Error Handling**: Current tests use `Test.expect(result, Test.beSucceeded())`. Consider adding more specific error checking.

4. **Full Integration Tests**: Future work could create end-to-end tests that simulate complete user flows with FlowToken.

## Branches Created
- `feature/flowtoken-integration` - Contains FlowToken test helpers and additional utilities (kept separate for cleanliness)
- Current branch has the minimal working FlowToken integration

## Key Takeaways
1. FlowToken integration is straightforward once you understand the testing framework addresses
2. Avoiding inline code is critical for test stability
3. The Cadence 1.0 changes (like Burner integration) need to be accounted for
4. Clear separation between test helpers and production code is important
5. Both MockVault and FlowToken patterns can coexist for different testing needs 