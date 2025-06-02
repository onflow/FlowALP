# Oracle Restoration Technical Plan

## Overview

This document outlines the technical approach for restoring Dieter Shirley's comprehensive oracle implementation while preserving the new features added (MOET, FlowToken, Governance).

## Key Components to Restore

### 1. Core Oracle Infrastructure

#### PriceOracle Interface
```cadence
access(all) struct interface PriceOracle {
    access(all) view fun unitOfAccount(): Type
    access(all) fun price(token: Type): UFix64
}
```

#### Pool Modifications
- Add `priceOracle: {PriceOracle}` field
- Restore `collateralFactor: {Type: UFix64}` and `borrowFactor: {Type: UFix64}`
- Remove simplified `exchangeRates` and `liquidationThresholds`

### 2. Position Management

#### Restore InternalPosition Resource
- Convert from struct back to resource (as Dieter designed)
- Add queued deposits mechanism
- Add health bounds (min/max/target)
- Add sink/source management

#### Advanced Position Functions
- `positionBalanceSheet()` - Full oracle-based calculations
- `healthAfterDeposit()`
- `healthAfterWithdrawal()`  
- `fundsRequiredForTargetHealth()`
- `fundsAvailableAboveTargetHealth()`

### 3. Risk Management

#### Dynamic Risk Assessment
- Per-token collateral factors (e.g., 0.8 for ETH, 1.0 for stables)
- Per-token borrow factors
- Price-based effective collateral/debt calculations

#### Position Rebalancing
- Automated position updates queue
- Draw-down sink integration
- Top-up source integration

### 4. Integration Points

#### MOET Integration
- Add MOET to collateral/borrow factor mappings
- Configure as approved stable (factor: 1.0)

#### FlowToken Integration  
- Configure FLOW as established crypto (factor: 0.8)
- Ensure compatibility with native token operations

#### Governance Integration
- Oracle updates through governance proposals
- Factor adjustments via governance
- Emergency pause for price anomalies

## Implementation Strategy

### Phase 1: Core Oracle Restoration
1. Create `DummyPriceOracle` for testing
2. Restore PriceOracle integration in Pool
3. Update positionHealth to use oracle prices
4. Restore collateral/borrow factors

### Phase 2: Advanced Features
1. Restore InternalPosition as resource
2. Implement position balance sheet
3. Add health calculation functions
4. Restore deposit/withdrawal logic

### Phase 3: Risk Management
1. Implement position update queue
2. Add sink/source interfaces
3. Create rebalancing logic
4. Add deposit rate limiting

### Phase 4: Testing & Integration
1. Create oracle mock for tests
2. Update all tests to provide oracle
3. Test with MOET and FlowToken
4. Verify governance controls

## Key Differences to Preserve

While restoring Dieter's code, we must preserve:
1. MOET token contract and integration
2. FlowToken native support (no mock vault)
3. Governance entitlements on addSupportedToken
4. Test infrastructure improvements

## Migration Notes

### From Static to Dynamic
Current static implementation:
```cadence
effectiveCollateral = trueBalance * self.liquidationThresholds[type]!
```

Restored oracle implementation:
```cadence
let tokenPrice = self.priceOracle.price(token: type)
effectiveCollateral = effectiveCollateral + (trueBalance * tokenPrice * self.collateralFactor[type]!)
```

### Pool Constructor Changes
Current:
```cadence
init(defaultToken: Type, defaultTokenThreshold: UFix64)
```

Restored:
```cadence
init(defaultToken: Type, priceOracle: {PriceOracle})
```

## Test Oracle Implementation

```cadence
access(all) struct DummyPriceOracle: PriceOracle {
    access(self) var prices: {Type: UFix64}
    access(self) let defaultToken: Type
    
    access(all) view fun unitOfAccount(): Type {
        return self.defaultToken
    }
    
    access(all) fun price(token: Type): UFix64 {
        return self.prices[token] ?? 1.0
    }
    
    access(all) fun setPrice(token: Type, price: UFix64) {
        self.prices[token] = price
    }
    
    init(defaultToken: Type) {
        self.defaultToken = defaultToken
        self.prices = {defaultToken: 1.0}
    }
}
```

## Success Criteria

1. All of Dieter's oracle functionality restored
2. Dynamic price-based health calculations working
3. MOET and FlowToken fully integrated
4. All tests passing with oracle
5. Governance controls maintained
6. No loss of new features

## Next Steps

1. Start with DummyPriceOracle implementation
2. Update Pool to accept oracle in constructor
3. Restore position health calculations
4. Migrate tests incrementally
5. Document all changes 