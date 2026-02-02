# TODO and Missing Tests Summary

## TODOs in Existing Code

### Test Files
1. **`position_lifecycle_happy_test.cdc`** (Line 64)
   - TODO: Implement test for closing position when `close_position` transaction exists
   - Currently missing: Repay and close position functionality

2. **`reserve_withdrawal_test.cdc`** (Line 28)
   - TODO: Once contract exposes direct mint-to-reserve path
   - Currently skipping balance assertion due to missing functionality

### Transaction Files
1. **`repay_and_close_position.cdc`** (Line 13)
   - TODO: Implement when FlowALPv1.Pool exposes position info and repayAndClosePosition
   - Currently just a placeholder that panics

2. **`withdraw_reserve.cdc`** (Lines 16, 22)
   - TODO: Implement proper governance control
   - TODO: Once FlowALPv1.Pool exposes a withdrawReserve function
   - Currently using a workaround that creates empty vaults

### Contract Files
1. **`FlowALPv1.cdc`** (Line 1389)
   - TODO: In production, asyncUpdate() should only process limited positions per callback
   - TODO: Schedule each update in its own callback for error isolation

2. **`FlowALPv1.cdc`** (Line 1452)
   - TODO: Consider making Position a resource given its critical role

## Missing Tests (From Test Plan)

Based on `FlowALPv1_TestPlan.md`, all planned tests have been implemented:
- ✅ Pool Creation Workflow
- ✅ Supported Token Governance Addition 
- ✅ Position Lifecycle Happy Path (partial - missing close)
- ✅ Rebalance Undercollateralised
- ✅ Rebalance Overcollateralised
- ✅ Reserve Withdrawal Governance Control

## Missing Features Requiring Tests (From FutureFeatures.md)

### Tracer Bullet Phase
1. **Functional Sink/Source Hooks** (Critical)
   - Tests E-1: Push to sink on surplus
   - Tests E-2: Pull from source on shortfall

2. **Basic Oracle Integration**
   - Oracle price updates
   - Stale price handling
   - Price manipulation protection

### Limited Beta Phase
1. **Multi-Token Support**
   - Deposit multiple token types
   - Borrow against multi-token collateral
   - Token-specific thresholds

2. **Advanced Position Management**
   - YieldVault resource creation/management
   - Position tracking and metadata
   - IRR calculations

3. **Automated Rebalancing**
   - Automatic rebalance triggers
   - Collateral accumulation

4. **Access Control & Limits**
   - User whitelisting
   - Per-user collateral limits

### Open Beta Phase
1. **Production Oracle Integration**
   - Multi-oracle aggregation
   - Oracle failover

2. **Advanced Interest Curves**
   - Interest accrual over time
   - Dynamic rate adjustment

## Priority Implementation Order

### High Priority (Contract Functionality Missing)
1. **Position Close/Repay functionality**
   - Contract method: `repayAndClosePosition()`
   - Transaction: `repay_and_close_position.cdc`
   - Test completion: `position_lifecycle_happy_test.cdc`

2. **Reserve Management**
   - Contract method: `withdrawReserve()` with governance
   - Direct mint-to-reserve capability
   - Complete test assertions in `reserve_withdrawal_test.cdc`

### Medium Priority (Production Readiness)
1. **Async Update Improvements**
   - Batch processing limits
   - Error isolation per position update

2. **Position as Resource**
   - Architectural change for better security

### Future Features (Per Roadmap)
1. Sink/Source integration tests
2. Oracle integration tests
3. Multi-token support tests
4. Access control tests

## Test Coverage Gaps

Current tests cover:
- Basic pool operations
- Position creation and rebalancing
- Auto-borrowing behavior
- Token governance

Missing test coverage for:
- Position closing/repayment
- Error scenarios and edge cases
- Multi-position scenarios
- Concurrent operations
- Gas optimization scenarios
- Integration with real DeFi protocols 

## HIGH PRIORITY - Critical Missing Functionality

### 1. Position Close/Repay Functionality
**Status**: Partially implemented - repayment works but collateral return blocked  
**Issue**: No way to fully close a position and return collateral to user  
**Location**: `FlowALPv1.cdc` - Pool contract missing helper method  

**Current State (Demonstrated in Tests)**:
- Created `repay_and_close_position.cdc` transaction that repays MOET debt successfully
- Transaction includes detailed logging showing position state before/after
- **Before repayment**: MOET: 615.38 Debit, Flow: 1000.00 Credit
- **After repayment**: MOET: 0.00 (cleared ✅), Flow: 1000.00 Credit (still locked ❌)
- Cannot return collateral because `Position.withdraw()` requires `FungibleToken.Withdraw` authorization
- User's Flow collateral remains locked in position after full debt repayment

**What's Needed**:
1. Contract method like `repayAndClosePosition()` that handles both repayment and collateral return internally
2. OR expose a way to grant transactions `FungibleToken.Withdraw` access to Position methods
3. Current workaround leaves collateral stranded - users can repay but cannot recover their assets

**Test Coverage**: 
- `position_lifecycle_happy_test.cdc` tests repayment (passes)
- Test includes logging that clearly demonstrates the issue
- Collateral return test commented out pending contract support 
