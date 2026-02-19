# Security Permission Matrix

Maps each entitlement to the operations it permits. For audit/security review.

## Entitlements (FlowALPv0)

| Entitlement | Who holds it |
|---|---|
| `EParticipant` | Any external user (beta users, public) |
| `EPosition` | ⚠️ Protocol-internal operators only — NOT end users. Grants pool-wide access to operate on **any** position by ID, with no ownership check. |
| `ERebalance` | Rebalancer contracts |
| `EPositionAdmin` | Position owner only |
| `EGovernance` | Protocol admins only |
| `EImplementation` | Internal protocol use only |

## Permission Matrix

| Resource | Operation | Description | EParticipant | EPosition | ERebalance | EPositionAdmin | EGovernance | EImplementation |
|---|---|---|---|---|---|---|---|---|
| **Pool** | `createPosition` | A user can open a new position | ✅ | | | | | |
| **Pool** | `depositToPosition` | A user can deposit collateral | ✅ | | | | | |
| **Pool** | `withdraw` | ⚠️ Withdraw from **any** position by ID — no ownership check | | ✅ | | | | |
| **Pool** | `depositAndPush` | ⚠️ Push funds from **any** position to its drawdown sink | | ✅ | | | | |
| **Pool** | `withdrawAndPull` | ⚠️ Withdraw from **any** position, pulling from its top-up source | | ✅ | | | | |
| **Pool** | `lockPosition` | ⚠️ Freeze **any** position from updates | | ✅ | | | | |
| **Pool** | `unlockPosition` | ⚠️ Unfreeze **any** position | | ✅ | | | | |
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

## ⚠️ Known Issue: Beta Capability Over-Grant

`publish_beta_cap.cdc` and `claim_and_save_beta_cap.cdc` currently grant `EParticipant + EPosition` to beta users.

`EPosition` is **not needed** for normal user actions (create/deposit). Because `EPosition` gates pool-level `withdraw(pid:)` with no ownership check, any beta user can withdraw funds from **any other user's position**.

**Fix:** Remove `EPosition` from the beta capability — grant `EParticipant` only.
