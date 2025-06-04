# TidalProtocol Developer Quick Reference

## Critical Rules (NEVER BREAK THESE)

### 1. Always Use tokenState()
```cadence
// ❌ WRONG - Never access globalLedger directly
let state = &self.globalLedger[type]!

// ✅ CORRECT - Always use tokenState()
let tokenState = self.tokenState(type: type)
```

### 2. InternalPosition is a Resource
```cadence
// InternalPosition MUST remain a resource
access(all) resource InternalPosition {
    // Never convert back to struct!
}
```

### 3. Health Must Stay Above 1.0
```cadence
// Always check after withdrawals
assert(self.positionHealth(pid: pid) >= 1.0, message: "Position is overdrawn")
```

## Known Issues & Solutions

### Empty Vault Creation (PRIORITY 1 FIX)
```cadence
// ISSUE: Cannot create empty vaults
// TEMPORARY: Will panic with "Cannot create empty vault for type"

// SOLUTION (to be implemented):
// 1. Add to Pool resource
access(self) var vaultPrototypes: @{Type: {FungibleToken.Vault}}

// 2. Store prototype when adding token
let emptyVault <- tokenContract.createEmptyVault()
self.vaultPrototypes[tokenType] <-! emptyVault

// 3. Use prototype to create empty vaults
let prototype = &self.vaultPrototypes[type] as &{FungibleToken.Vault}
return <- prototype.createEmptyVault()
```

## API Differences from Dieter's AlpenFlow

### Position Methods
```cadence
// Our API (cleaner - Position knows its ID)
position.deposit(from: <-vault)

// Dieter's API (requires pid parameter)
position.deposit(pid: pid, from: <-vault)

// Compatibility alias (if needed)
position.provideSink(sink)         // Our name
position.provideDrawDownSink(sink) // Dieter's name
```

### Interface Names
```cadence
// We use namespaced interfaces (prevents conflicts)
let sink: {DFB.Sink}
let vault: @{FungibleToken.Vault}

// Dieter uses simple names
let sink: {Sink}
let vault: @{Vault}
```

## Common Operations

### Creating a Pool
```cadence
// With dummy oracle (testing only)
let pool <- TidalProtocol.createTestPoolWithOracle(
    defaultToken: Type<@FlowToken.Vault>()
)

// With real oracle
let oracle = MyPriceOracle()
let pool <- TidalProtocol.createPool(
    defaultToken: Type<@FlowToken.Vault>(),
    priceOracle: oracle
)
```

### Adding Supported Tokens
```cadence
// Risk parameters based on token type
pool.addSupportedToken(
    tokenType: Type<@MOET.Vault>(),
    collateralFactor: 1.0,    // 100% for stables
    borrowFactor: 0.9,        // 90% efficiency
    interestCurve: SimpleInterestCurve(),
    depositRate: 1000.0,      // tokens/second
    depositCapacityCap: 1000000.0
)

// Set oracle price
oracle.setPrice(token: Type<@MOET.Vault>(), price: 1.0)
```

### Position Operations
```cadence
// Create position
let pid = pool.createPosition()
let position = pool.borrowPosition(pid: pid)

// Simple deposit (no immediate rebalance)
position.deposit(from: <-vault)

// Enhanced deposit (with optional rebalance)
position.depositAndPush(
    from: <-vault,
    pushToDrawDownSink: true  // Force rebalance
)

// Simple withdraw (no backup source)
let withdrawn <- position.withdraw(
    type: Type<@FlowToken.Vault>(),
    amount: 100.0
)

// Enhanced withdraw (with backup source)
let withdrawn <- position.withdrawAndPull(
    type: Type<@FlowToken.Vault>(),
    amount: 100.0,
    pullFromTopUpSource: true  // Use backup funds
)
```

### Sink/Source Integration
```cadence
// Create basic sink/source
let sink = position.createSink(type: Type<@FlowToken.Vault>())
let source = position.createSource(type: Type<@FlowToken.Vault>())

// Create enhanced sink/source
let sink = position.createSinkWithOptions(
    type: Type<@FlowToken.Vault>(),
    pushToDrawDownSink: true  // Auto-rebalance on deposit
)

let source = position.createSourceWithOptions(
    type: Type<@FlowToken.Vault>(),
    pullFromTopUpSource: true  // Use backup on withdraw
)

// Provide external sink/source (auto-rebalancing)
position.provideSink(sink: externalSink)
position.provideSource(source: externalSource)
```

## Testing Guidelines

### Basic Test Setup
```cadence
// Create pool with oracle
let oracle = DummyPriceOracle(defaultToken: Type<@FlowToken.Vault>())
let pool <- TidalProtocol.createPool(
    defaultToken: Type<@FlowToken.Vault>(),
    priceOracle: oracle
)

// Set prices
oracle.setPrice(token: Type<@FlowToken.Vault>(), price: 5.0)
oracle.setPrice(token: Type<@MOET.Vault>(), price: 1.0)

// Add tokens with risk parameters
pool.addSupportedToken(
    tokenType: Type<@MOET.Vault>(),
    collateralFactor: 1.0,
    borrowFactor: 0.9,
    interestCurve: SimpleInterestCurve(),
    depositRate: 1000.0,
    depositCapacityCap: 1000000.0
)
```

### Testing Rate Limiting
```cadence
// Deposit more than 5% capacity
let largeVault <- flowVault.withdraw(amount: 100000.0)
position.deposit(from: <-largeVault)

// Check queued deposits
let details = pool.getPositionDetails(pid: pid)
// Only 5% should be deposited immediately
// Rest should be queued for async processing
```

### Testing Price Changes
```cadence
// Change collateral price
oracle.setPrice(token: Type<@FlowToken.Vault>(), price: 2.0)

// Check health impact
let newHealth = pool.positionHealth(pid: pid)
// Health should decrease with price drop

// Trigger rebalancing
pool.rebalancePosition(pid: pid, force: true)
// Should trigger sink/source operations
```

## Helper Functions (Public in Our Implementation)

```cadence
// Interest calculations (made public for testing)
TidalProtocol.interestMul(a: UInt64, b: UInt64): UInt64
TidalProtocol.perSecondInterestRate(yearlyRate: UFix64): UInt64
TidalProtocol.compoundInterestIndex(oldIndex: UInt64, perSecondRate: UInt64, elapsedSeconds: UFix64): UInt64
TidalProtocol.scaledBalanceToTrueBalance(scaledBalance: UFix64, interestIndex: UInt64): UFix64
TidalProtocol.trueBalanceToScaledBalance(trueBalance: UFix64, interestIndex: UInt64): UFix64
```

## Production Checklist

- [ ] **Fix empty vault issue first**
- [ ] Replace DummyPriceOracle with real oracle
- [ ] Set appropriate collateral/borrow factors
- [ ] Configure deposit rate limits
- [ ] Implement liquidation logic
- [ ] Add monitoring for position health
- [ ] Set up alerts for large deposits/withdrawals
- [ ] Audit smart contracts
- [ ] Test all edge cases
- [ ] Document emergency procedures

## Quick Debugging

### Check Position State
```cadence
let details = pool.getPositionDetails(pid: pid)
log("Health: ".concat(details.health.toString()))
log("Balances: ".concat(details.balances.length.toString()))
```

### Verify Oracle Prices
```cadence
let flowPrice = oracle.price(token: Type<@FlowToken.Vault>())
let moetPrice = oracle.price(token: Type<@MOET.Vault>())
log("FLOW: ".concat(flowPrice.toString()))
log("MOET: ".concat(moetPrice.toString()))
```

### Test Rebalancing
```cadence
pool.rebalancePosition(pid: pid, force: true)
// Check if sink/source were called
```

## Remember

> "Dieter's code is the holy grail. We build upon it, never against it."

**Current Status**: 100% functionally complete with one known issue (empty vault creation) 