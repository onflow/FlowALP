# Security Permission Matrix

Maps each entitlement to the operations it permits. For audit/security review.

## Entitlements (FlowALPv0)

| Entitlement | Who holds it |
|---|---|
| `EParticipant` | Any external user |
| `EPosition` | Position operators |
| `ERebalance` | Rebalancer contracts |
| `EPositionAdmin` | Position owner |
| `EGovernance` | Protocol admins only |
| `EImplementation` | Internal protocol use only |

## Permission Matrix

| Resource | Operation | Description | EParticipant | EPosition | ERebalance | EPositionAdmin | EGovernance | EImplementation |
|---|---|---|---|---|---|---|---|---|
| **Pool** | `createPosition` | A user can open a new position | ✅ | | | | | |
| **Pool** | `depositToPosition` | A user can deposit collateral | ✅ | | | | | |
| **Pool** | `withdraw` | An operator can withdraw from a position | | ✅ | | | | |
| **Pool** | `depositAndPush` | Push excess funds to drawdown sink | | ✅ | | | | |
| **Pool** | `withdrawAndPull` | Pull funds from top-up source on withdraw | | ✅ | | | | |
| **Pool** | `lockPosition` | Prevent updates to a position | | ✅ | | | | |
| **Pool** | `unlockPosition` | Re-enable updates to a position | | ✅ | | | | |
| **Pool** | `rebalancePosition` | Rebalance a position's health | | ✅ | ✅ | | | |
| **Pool** | `pausePool` / `unpausePool` | Halt or resume all pool operations | | | | | ✅ | |
| **Pool** | `addSupportedToken` | Add a new collateral/borrow token | | | | | ✅ | |
| **Pool** | `setInterestCurve` | Configure interest rate model | | | | | ✅ | |
| **Pool** | `setInsuranceRate` | Set the insurance fee rate | | | | | ✅ | |
| **Pool** | `setStabilityFeeRate` | Set the stability fee rate | | | | | ✅ | |
| **Pool** | `setLiquidationParams` | Configure liquidation thresholds | | | | | ✅ | |
| **Pool** | `setPauseParams` | Configure pause conditions | | | | | ✅ | |
| **Pool** | `setDepositLimitFraction` | Cap deposits as fraction of pool | | | | | ✅ | |
| **Pool** | `collectInsurance` | Sweep insurance fees to treasury | | | | | ✅ | |
| **Pool** | `withdrawStabilityFund` | Withdraw from stability reserve | | | | | ✅ | |
| **Pool** | `setDEX` / `setPriceOracle` | Set liquidation DEX or price feed | | | | | ✅ | |
| **Pool** | `asyncUpdate` | Process queued state updates (internal) | | | | | | ✅ |
| **Pool** | `regenerateAllDepositCapacities` | Recalculate deposit caps (internal) | | | | | | ✅ |
| **Position** | `rebalance` | Rebalance this position's health | | ✅ | ✅ | | | |
| **Position** | `setTargetHealth` | Set the health ratio the rebalancer aims for | | | | ✅ | | |
| **Position** | `setMinHealth` | Set the minimum health before auto-borrow | | | | ✅ | | |
| **Position** | `setMaxHealth` | Set the maximum health before auto-repay | | | | ✅ | | |
| **Position** | `provideSink` | Configure where excess funds are sent | | | | ✅ | | |
| **Position** | `provideSource` | Configure where top-up funds come from | | | | ✅ | | |
| **Position** | `asyncUpdatePosition` | Process queued update for this position (internal) | | | | | | ✅ |
| **PositionManager** | `addPosition` | Add a position to the manager | | | | ✅ | | |
| **PositionManager** | `removePosition` | Remove a position from the manager | | | | ✅ | | |
| **PositionManager** | `borrowAuthorizedPosition` | Borrow a position with withdrawal rights | | | | ✅ | | |
| **Rebalancer** | `setRecurringConfig` | Change the rebalance schedule/config | `Configure`¹ | | | | | |
| **RebalancerPaid** | `delete` | Stop and remove a paid rebalancer | `Delete`¹ | | | | | |

¹ Contract-local entitlements in `FlowALPRebalancerv1` / `FlowALPRebalancerPaidv1`, not part of the FlowALPv0 hierarchy.

## Audit Notes

- `rebalancePosition` / `rebalance` use `EPosition | ERebalance` — **either** entitlement is sufficient (union, not conjunction)
- `borrowAuthorizedPosition` requires `FungibleToken.Withdraw + EPositionAdmin` — **both** required (conjunction)
- `EImplementation` maps to `Mutate + FungibleToken.Withdraw` via the `ImplementationUpdates` entitlement mapping — never issued to external accounts
