# Security Permission Matrix

Maps each entitlement to the operations it permits. For audit/security review.

## Entitlements → Actors

| Entitlement | Actor | How granted |
|---|---|---|
| `EParticipant` | User | Published capability (`publish_beta_cap.cdc`) |
| `EPosition` | ⚠️ Protocol operator (NOT end users) | Published capability (`publish_beta_cap.cdc`) ← **over-grant** |
| `ERebalance` | Rebalancer contract | Rebalancer setup |
| `EPositionAdmin` | User (own positions only) | Storage ownership of `PositionManager` — cannot be delegated |
| `EGovernance` | Protocol admin | Admin account |
| `EImplementation` | Protocol internals | Never issued externally |

## Actor Capability Matrix

| Operation | Description | User (EParticipant) | ⚠️ User w/ EPosition (current beta) | Rebalancer (ERebalance) | User — own positions only (EPositionAdmin) | Governance (EGovernance) | Protocol Internal (EImplementation) |
|---|---|---|---|---|---|---|---|
| `createPosition` | Open a new position | ✅ | ✅ | | | | |
| `depositToPosition` | Deposit collateral | ✅ | ✅ | | | | |
| `withdraw` | ⚠️ Withdraw from **any** position by ID | | ✅ | | | | |
| `withdrawAndPull` | ⚠️ Withdraw from **any** position + pull top-up | | ✅ | | | | |
| `depositAndPush` | ⚠️ Push funds from **any** position | | ✅ | | | | |
| `lockPosition` | ⚠️ Freeze **any** position | | ✅ | | | | |
| `unlockPosition` | ⚠️ Unfreeze **any** position | | ✅ | | | | |
| `rebalancePosition` | Rebalance a position's health | | ✅ | ✅ | | | |
| `rebalance` (Position) | Rebalance this position | | ✅ | ✅ | | | |
| `setTargetHealth` | Set target health ratio | | | | ✅ | | |
| `setMinHealth` | Set min health before auto-borrow | | | | ✅ | | |
| `setMaxHealth` | Set max health before auto-repay | | | | ✅ | | |
| `provideSink` | Configure drawdown sink | | | | ✅ | | |
| `provideSource` | Configure top-up source | | | | ✅ | | |
| `addPosition` (Manager) | Add position to manager | | | | ✅ | | |
| `removePosition` (Manager) | Remove position from manager | | | | ✅ | | |
| `borrowAuthorizedPosition` | Borrow position with withdrawal rights¹ | | | | ✅ | | |
| `pausePool` / `unpausePool` | Halt or resume all pool operations | | | | | ✅ | |
| `addSupportedToken` | Add a new collateral/borrow token | | | | | ✅ | |
| `setInterestCurve` | Configure interest rate model | | | | | ✅ | |
| `setInsuranceRate` | Set the insurance fee rate | | | | | ✅ | |
| `setStabilityFeeRate` | Set the stability fee rate | | | | | ✅ | |
| `setLiquidationParams` | Configure liquidation thresholds | | | | | ✅ | |
| `setPauseParams` | Configure pause conditions | | | | | ✅ | |
| `setDepositLimitFraction` | Cap deposits as fraction of pool | | | | | ✅ | |
| `collectInsurance` | Sweep insurance fees to treasury | | | | | ✅ | |
| `withdrawStabilityFund` | Withdraw from stability reserve | | | | | ✅ | |
| `setDEX` / `setPriceOracle` | Set liquidation DEX or price feed | | | | | ✅ | |
| `asyncUpdate` | Process queued state updates | | | | | | ✅ |
| `asyncUpdatePosition` | Process queued update for one position | | | | | | ✅ |
| `regenerateAllDepositCapacities` | Recalculate all deposit caps | | | | | | ✅ |
| `setRecurringConfig` (Rebalancer) | Change rebalance schedule | `Configure`² | | | | | |
| `delete` (RebalancerPaid) | Stop and remove paid rebalancer | `Delete`² | | | | | |

¹ `borrowAuthorizedPosition` requires `FungibleToken.Withdraw + EPositionAdmin` — both required (conjunction).
² Contract-local entitlements in `FlowALPRebalancerv1` / `FlowALPRebalancerPaidv1`, not part of the FlowALPv0 hierarchy.

## ⚠️ Known Issue: Beta Capability Over-Grant

`publish_beta_cap.cdc` grants `EParticipant + EPosition` to beta users (the "⚠️ User w/ EPosition" column above).

`EPosition` is **not needed** for normal user actions (create/deposit). The ⚠️ rows above are all unlocked for beta users, meaning any beta user can withdraw funds from or freeze **any other user's position**.

**Fix:** Remove `EPosition` from the beta capability — grant `EParticipant` only.

## Audit Notes

- `rebalancePosition` / `rebalance` use `EPosition | ERebalance` — **either** entitlement is sufficient (union, not conjunction)
- `EImplementation` maps to `Mutate + FungibleToken.Withdraw` via the `ImplementationUpdates` entitlement mapping — never issued externally
