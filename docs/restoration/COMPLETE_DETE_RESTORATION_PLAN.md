# Complete Restoration Plan for Dieter's AlpenFlow/TidalProtocol

## Executive Summary

After thorough comparison of Dieter Shirley's latest commit (9603340) with our current implementation, we're missing approximately 40% of critical functionality. This document provides a complete restoration plan.

## Phase 1: Critical Infrastructure (Immediate)

### 1.1 Convert InternalPosition to Resource
```cadence
access(all) resource InternalPosition {
    access(mapping ImplementationUpdates) var balances: {Type: InternalBalance}
    access(mapping ImplementationUpdates) var queuedDeposits: @{Type: {FungibleToken.Vault}}
    access(EImplementation) var targetHealth: UFix64
    access(EImplementation) var minHealth: UFix64
    access(EImplementation) var maxHealth: UFix64
    access(EImplementation) var drawDownSink: {DFB.Sink}?
    access(EImplementation) var topUpSource: {DFB.Source}?
}
```

### 1.2 Extend TokenState
```cadence
access(all) struct TokenState {
    // ... existing fields ...
    access(all) var depositRate: UFix64
    access(all) var depositCapacity: UFix64
    access(all) var depositCapacityCap: UFix64
    
    access(all) fun depositLimit(): UFix64 {
        return self.depositCapacity * 0.05
    }
    
    access(all) fun updateForTimeChange() {
        // ... existing code ...
        let newDepositCapacity = self.depositCapacity + (self.depositRate * timeDelta)
        if newDepositCapacity >= self.depositCapacityCap {
            self.depositCapacity = self.depositCapacityCap
        } else {
            self.depositCapacity = newDepositCapacity
        }
    }
}
```

### 1.3 Add Position Update Queue to Pool
```cadence
access(EImplementation) var positionsNeedingUpdates: [UInt64]
access(self) var positionsProcessedPerCallback: UInt64
```

## Phase 2: Position Health Management Functions

### 2.1 Core Health Calculation Functions
All these functions must be added to Pool resource:

```cadence
// The quantity of funds needed to reach target health
access(all) fun fundsRequiredForTargetHealth(
    pid: UInt64, 
    type: Type, 
    targetHealth: UFix64
): UFix64

// The quantity of funds needed after withdrawing
access(all) fun fundsRequiredForTargetHealthAfterWithdrawing(
    pid: UInt64, 
    depositType: Type, 
    targetHealth: UFix64,
    withdrawType: Type, 
    withdrawAmount: UFix64
): UFix64

// The quantity available above target health
access(all) fun fundsAvailableAboveTargetHealth(
    pid: UInt64, 
    type: Type, 
    targetHealth: UFix64
): UFix64

// The quantity available after depositing
access(all) fun fundsAvailableAboveTargetHealthAfterDepositing(
    pid: UInt64, 
    withdrawType: Type, 
    targetHealth: UFix64,
    depositType: Type, 
    depositAmount: UFix64
): UFix64

// Health after deposit
access(all) fun healthAfterDeposit(
    pid: UInt64, 
    type: Type, 
    amount: UFix64
): UFix64

// Health after withdrawal
access(all) fun healthAfterWithdrawal(
    pid: UInt64, 
    type: Type, 
    amount: UFix64
): UFix64
```

### 2.2 Implementation Logic
These functions contain complex logic for:
- Handling debt/credit flip scenarios
- Price oracle integration
- Collateral/borrow factor calculations
- Edge case handling (zero debt, overflow prevention)

## Phase 3: Deposit Queue and Rate Limiting

### 3.1 Deposit Queue Processing
```cadence
access(EPosition) fun depositAndPush(
    pid: UInt64, 
    from: @{FungibleToken.Vault}, 
    pushToDrawDownSink: Bool
) {
    // Check deposit limit
    let depositLimit = tokenState.depositLimit()
    if from.balance > depositLimit {
        // Queue excess deposit
        let queuedDeposit <- from.withdraw(amount: from.balance - depositLimit)
        if position.queuedDeposits[type] == nil {
            position.queuedDeposits[type] <-! queuedDeposit
        } else {
            position.queuedDeposits[type]!.deposit(from: <-queuedDeposit)
        }
    }
    // ... rest of deposit logic
}
```

### 3.2 Async Queue Processing
```cadence
access(EImplementation) fun asyncUpdatePosition(pid: UInt64) {
    // Process queued deposits
    for depositType in position.queuedDeposits.keys {
        let queuedVault <- position.queuedDeposits.remove(key: depositType)!
        let maxDeposit = depositTokenState.depositLimit()
        if maxDeposit >= queuedVault.balance {
            self.depositAndPush(pid: pid, from: <-queuedVault, pushToDrawDownSink: false)
        } else {
            // Partial deposit
            let depositVault <- queuedVault.withdraw(amount: maxDeposit)
            self.depositAndPush(pid: pid, from: <-depositVault, pushToDrawDownSink: false)
            position.queuedDeposits[depositType] <-! queuedVault
        }
    }
    // Rebalance position
    self.rebalancePosition(pid: pid, force: false)
}
```

## Phase 4: Rebalancing Infrastructure

### 4.1 Position Rebalancing
```cadence
access(EPosition) fun rebalancePosition(pid: UInt64, force: Bool) {
    let position = &self.positions[pid] as auth(EImplementation) &InternalPosition?!
    let balanceSheet = self.positionBalanceSheet(pid: pid)
    
    if !force && (balanceSheet.health >= position.minHealth && balanceSheet.health <= position.maxHealth) {
        return
    }
    
    if balanceSheet.health < position.targetHealth {
        // Pull from top-up source
        if position.topUpSource != nil {
            let idealDeposit = self.fundsRequiredForTargetHealth(/*...*/)
            let pulledVault <- topUpSource!.withdrawAvailable(maxAmount: idealDeposit)
            self.depositAndPush(pid: pid, from: <-pulledVault, pushToDrawDownSink: false)
        }
    } else if balanceSheet.health > position.targetHealth {
        // Push to draw-down sink
        if position.drawDownSink != nil {
            let idealWithdrawal = self.fundsAvailableAboveTargetHealth(/*...*/)
            let sinkVault <- self.withdrawAndPull(/*...*/)
            position.drawDownSink!.depositCapacity(from: &sinkVault /*...*/)
            self.depositAndPush(pid: pid, from: <-sinkVault, pushToDrawDownSink: false)
        }
    }
}
```

### 4.2 Queue Management
```cadence
access(self) fun queuePositionForUpdateIfNecessary(pid: UInt64) {
    if self.positionsNeedingUpdates.contains(pid) {
        return
    }
    
    let position = &self.positions[pid] as auth(EImplementation) &InternalPosition?!
    
    // Queue if has queued deposits
    if position.queuedDeposits.length > 0 {
        self.positionsNeedingUpdates.append(pid)
        return
    }
    
    // Queue if outside health bounds
    let positionHealth = self.positionHealth(pid: pid)
    if positionHealth < position.minHealth || positionHealth > position.maxHealth {
        self.positionsNeedingUpdates.append(pid)
        return
    }
}
```

## Phase 5: Enhanced Pool Functions

### 5.1 Public Deposit Function
```cadence
access(all) fun depositToPosition(pid: UInt64, from: @{FungibleToken.Vault}) {
    self.depositAndPush(pid: pid, from: <-from, pushToDrawDownSink: false)
}
```

### 5.2 Enhanced Withdraw Function
```cadence
access(EPosition) fun withdrawAndPull(
    pid: UInt64, 
    type: Type, 
    amount: UFix64, 
    pullFromTopUpSource: Bool
): @{FungibleToken.Vault} {
    // Check if withdrawal requires top-up
    let requiredDeposit = self.fundsRequiredForTargetHealthAfterWithdrawing(/*...*/)
    
    if requiredDeposit > 0.0 && pullFromTopUpSource && position.topUpSource != nil {
        // Pull from source first
        let pulledVault <- topUpSource!.withdrawAvailable(maxAmount: requiredDeposit)
        if pulledVault.balance >= requiredDeposit {
            self.depositAndPush(pid: pid, from: <-pulledVault, pushToDrawDownSink: false)
        } else {
            panic("Insufficient funds for withdrawal")
        }
    }
    // ... rest of withdrawal logic
}
```

### 5.3 Available Balance with Source Integration
```cadence
access(all) fun availableBalance(
    pid: UInt64, 
    type: Type, 
    pullFromTopUpSource: Bool
): UFix64 {
    let position = &self.positions[pid] as auth(EImplementation) &InternalPosition?!
    
    if pullFromTopUpSource && position.topUpSource != nil {
        let topUpSource = position.topUpSource!
        let sourceType = topUpSource.sourceType()
        let sourceAmount = topUpSource.minimumAvailable()
        
        return self.fundsAvailableAboveTargetHealthAfterDepositing(
            pid: pid, 
            withdrawType: type, 
            targetHealth: position.minHealth,
            depositType: sourceType, 
            depositAmount: sourceAmount
        )
    } else {
        return self.fundsAvailableAboveTargetHealth(
            pid: pid, 
            type: type, 
            targetHealth: position.minHealth
        )
    }
}
```

## Phase 6: Complete Position Implementation

### 6.1 Position Struct Updates
```cadence
access(all) struct Position {
    // ... existing fields ...
    
    access(all) fun getTargetHealth(): UFix64 {
        let pool = self.pool.borrow()!
        let position = pool.getInternalPosition(pid: self.id)
        return position.targetHealth
    }
    
    access(all) fun setTargetHealth(targetHealth: UFix64) {
        let pool = self.pool.borrow()!
        pool.setPositionTargetHealth(pid: self.id, targetHealth: targetHealth)
    }
    
    // Similar for minHealth and maxHealth
    
    access(all) fun depositAndPush(from: @{FungibleToken.Vault}, pushToDrawDownSink: Bool) {
        let pool = self.pool.borrow()!
        pool.depositAndPush(pid: self.id, from: <-from, pushToDrawDownSink: pushToDrawDownSink)
    }
    
    access(all) fun withdrawAndPull(type: Type, amount: UFix64, pullFromTopUpSource: Bool): @{FungibleToken.Vault} {
        let pool = self.pool.borrow()!
        return <- pool.withdrawAndPull(pid: self.id, type: type, amount: amount, pullFromTopUpSource: pullFromTopUpSource)
    }
    
    access(all) fun provideDrawDownSink(sink: {DFB.Sink}?) {
        let pool = self.pool.borrow()!
        pool.provideDrawDownSink(pid: self.id, sink: sink)
    }
    
    access(all) fun provideTopUpSource(source: {DFB.Source}?) {
        let pool = self.pool.borrow()!
        pool.provideTopUpSource(pid: self.id, source: source)
    }
}
```

### 6.2 Enhanced Sink/Source Structs
```cadence
access(all) struct PositionSink: DFB.Sink {
    access(self) let pushToDrawDownSink: Bool
    
    access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
        let pool = self.pool.borrow()!
        pool.depositAndPush(
            pid: self.id, 
            from: <-from.withdraw(amount: from.balance), 
            pushToDrawDownSink: self.pushToDrawDownSink
        )
    }
}

access(all) struct PositionSource: DFB.Source {
    access(all) let pullFromTopUpSource: Bool
    
    access(all) fun minimumAvailable(): UFix64 {
        let pool = self.pool.borrow()!
        return pool.availableBalance(
            pid: self.id, 
            type: self.type, 
            pullFromTopUpSource: self.pullFromTopUpSource
        )
    }
}
```

## Implementation Priority

### Immediate (Blocking Production):
1. Convert InternalPosition to resource
2. Add queuedDeposits mechanism
3. Implement all health calculation functions
4. Add deposit rate limiting

### High Priority:
1. Position update queue
2. Rebalancing logic
3. Sink/source integration
4. Enhanced deposit/withdraw functions

### Required for Launch:
1. Complete feature parity with Dieter's code
2. All async update mechanisms
3. Full test coverage of restored features

## Testing Requirements

### Unit Tests:
- Each health calculation function
- Deposit queue behavior
- Rate limiting logic
- Rebalancing scenarios

### Integration Tests:
- Multi-position updates
- Sink/source interaction
- Oracle price changes
- Edge cases (zero debt, overflow)

### Stress Tests:
- Large deposit queues
- Rapid rebalancing
- Multiple concurrent updates

## Migration Notes

1. **Data Migration**: Existing positions must be migrated from struct to resource
2. **State Initialization**: New fields (health bounds, queues) need defaults
3. **Backwards Compatibility**: Ensure existing integrations continue working
4. **Gradual Rollout**: Consider feature flags for new functionality

## Conclusion

Dieter's implementation is sophisticated and complete. Our current implementation is missing critical safety features:
- Deposit rate limiting prevents flash loan attacks
- Position queues enable gradual updates
- Health management functions enable precise control
- Rebalancing infrastructure maintains protocol stability

**All missing features must be restored before any production deployment.** 