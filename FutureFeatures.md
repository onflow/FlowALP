# AlpenFlow Future Features and Tests

This document lists features that are not yet implemented in the AlpenFlow contract, organized by Tidal milestone phases with priority indicators:

- ✅ **Must Have** - Critical features required for launch
- 💛 **Should Have** - Important features that significantly enhance the product
- 👌 **Could Have** - Desirable features that would improve the user experience
- ❌ **Won't Have (this time)** - Features planned for future releases

## Tracer Bullet Phase Features

### 1. ✅ Functional Sink/Source Hooks (Critical for Tidal Integration)

**Features to Implement:**
- Real Sink implementation for pushing tokens to yield strategies
- Real Source implementation for pulling tokens from yield strategies
- Basic rebalancing logic

**Tests to Add (E-series):**
```
E-1: Push to sink on surplus
- Provide StakeSink
- When health = 2.0, excess pushed to sink
- Verify reserves decrease

E-2: Pull from source on shortfall
- Provide DummySource with 10 FLOW
- Slash price so HF < 1
- Call rebalance()
- Verify source supplies FLOW, health >= 1
```

### 2. 💛 Basic Oracle Integration

**Features to Implement:**
- Simple price oracle interface
- Manual price updates for testing
- Price staleness checks

**Tests to Add:**
```
- Oracle price updates
- Stale price handling
- Price manipulation protection
```

## Limited Beta Phase Features

### 3. ✅ Multi-Token Support

**Features to Implement:**
- Support for FLOW and USD as collateral
- Support for 2+ yield tokens
- Token whitelisting mechanism
- Per-token configuration

**Tests to Add:**
```
- Deposit multiple token types
- Borrow against multi-token collateral
- Token-specific thresholds
- Exchange rate updates
```

### 4. ✅ Advanced Position Management

**Features to Implement:**
- Tide resource in user's account
- Position tracking and metadata
- IRR calculations
- Trade history export

**Tests to Add:**
```
- Create Tide resource
- Track position metrics
- Calculate returns
- Export trade data
```

### 5. 💛 Automated Rebalancing

**Features to Implement:**
- Periodic rebalancing based on price changes
- Accumulation of additional collateral
- Protocol scheduled callbacks (if available)

**Tests to Add:**
```
- Automatic rebalance triggers
- Collateral accumulation
- Rebalance frequency limits
```

### 6. ✅ Access Control & Limits

**Features to Implement:**
- User whitelisting for beta
- Per-user collateral limits
- Configurable limits by admin

**Tests to Add:**
```
- Whitelist enforcement
- Deposit limits
- Limit updates
```

## Open Beta Phase Features

### 7. ✅ Production Oracle Integration

**Features to Implement:**
- Multiple oracle sources
- Oracle aggregation
- Non-FF operated oracles

**Tests to Add:**
```
- Multi-oracle aggregation
- Oracle failover
- Price consensus
```

### 8. 💛 Advanced Interest Curves

**Features to Implement:**
- Replace SimpleInterestCurve with real curves
- Multiple interest curve models
- Dynamic rate adjustment

**Tests to Add:**
```
- Interest accrual over time
- Rate changes based on utilization
- Compound interest calculations
```

## Future Releases (Won't Have This Time)

### 9. ❌ Liquidation Mechanism

**Features to Implement:**
- Liquidator role/capability
- Liquidation function
- Liquidation incentives/penalties

### 10. ❌ Flash Loan Support

**Features to Implement:**
- Flash loan interface
- Flash loan fees
- Reentrancy protection

### 11. ❌ Governance and Upgradability

**Features to Implement:**
- Governance capability/resource
- Hot-swappable components
- Parameter updates via governance

### 12. ❌ Deposit Queue with Rate Limiting

**Features to Implement:**
- Rate-limited deposit queue
- TPS throttling
- Queue processing scheduler

### 13. ❌ Emergency Controls

**Features to Implement:**
- Pause mechanism
- Emergency withdrawal
- Circuit breakers

## Implementation Priority

1. **Immediate (Tracer Bullet)**: Focus on sink/source integration and basic oracle
2. **Next (Limited Beta)**: Multi-token support, Tide resources, automated rebalancing
3. **Later (Open Beta)**: Production oracles, advanced interest curves
4. **Future**: Liquidations, flash loans, governance

## Test File Structure

```
cadence/tests/
├── current/                     # Existing tests
├── tracer_bullet/              # Tracer bullet phase
│   ├── sink_source_test.cdc    # E-series tests
│   └── basic_oracle_test.cdc   # Basic oracle tests
├── limited_beta/               # Limited beta phase
│   ├── multi_token_test.cdc    # Multi-token tests
│   ├── tide_resource_test.cdc  # Tide resource tests
│   ├── rebalancing_test.cdc    # Auto-rebalance tests
│   └── access_control_test.cdc # Access limit tests
├── open_beta/                  # Open beta phase
│   ├── prod_oracle_test.cdc    # Production oracle tests
│   └── interest_curves_test.cdc # Real interest tests
└── future/                     # Future releases
    ├── liquidation_test.cdc    # Liquidation tests
    ├── flash_loan_test.cdc     # Flash loan tests
    ├── governance_test.cdc     # Governance tests
    ├── deposit_queue_test.cdc  # Queue tests
    └── emergency_test.cdc      # Emergency tests
``` 