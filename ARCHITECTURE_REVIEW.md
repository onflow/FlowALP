# FlowALP Architecture Review & Improvement Proposals

> **Purpose**: Context document for follow-up sessions. Summarizes the current architecture, identifies issues, and proposes improvements.

## Current Architecture Summary

FlowALP is a lending/borrowing protocol on Flow. The core contracts are:

| Contract | LOC (approx) | Responsibility |
|---|---|---|
| `FlowALPv0` | ~2170 | Pool resource: deposits, withdrawals, liquidations, rebalancing, governance, fee collection, health computation |
| `FlowALPModels` | ~2300 | Data models, interfaces, and implementations for positions, pool state, pool config, token state, balance types, entitlements |
| `FlowALPHealth` | ~330 | Health math: adjusted balances after deposits/withdrawals, required deposits for target health |
| `FlowALPInterestRates` | ~140 | Interest curves: FixedCurve, KinkCurve |
| `FlowALPPositionResources` | ~510 | User-facing Position resource, PositionManager, PositionSink/PositionSource DeFiActions connectors |
| `FlowALPEvents` | ~320 | Centralized event definitions and `access(account)` emission functions |
| `FlowALPRebalancerv1` | ~340 | Self-custody scheduled rebalancer |
| `FlowALPRebalancerPaidv1` | ~180 | Managed (paid) rebalancer service |
| `FlowALPSupervisorv1` | ~66 | Cron-based supervisor for paid rebalancers |
| `PriceOracleAggregatorv1` | ~410 | Multi-source oracle aggregation with history stability |
| `PriceOracleRouterv1` | ~82 | Per-token oracle routing |
| `MOET` | ~215 | FungibleToken stablecoin (mean-of-exchange token) |

### Key Data Flow

```
User → Position resource (in user account)
         → Capability<EPosition> → Pool resource (in protocol account)
             → PoolState (reserves, token states, position queue, insurance/stability funds)
             → InternalPosition (per-position balances, queued deposits, sink/source)
             → PoolConfig (oracle, risk factors, DEX, pause state)
```

### Core Invariants

1. **Health Factor**: `H = effectiveCollateral / effectiveDebt ≥ 1.0` (liquidation threshold)
2. **Reserve solvency**: `reserve[T].balance ≥ Σ(credit balances for T) - Σ(debit balances for T)` — reserves back net deposits
3. **Interest index monotonicity**: credit/debit indices only increase
4. **Reentrancy**: position lock prevents concurrent operations on the same position

---

## Identified Issues

### 1. Pool is a God Object

`FlowALPv0.Pool` is a ~1200-line resource (within a ~2170-line contract) that handles:
- Position lifecycle (create, deposit, withdraw)
- Liquidation logic (manual liquidation with DEX price comparison)
- Rebalancing (under/overcollateralized positions, sink/source interaction)
- Interest rate management (time-based updates, compounding)
- Insurance fee collection (reserve withdrawal → swap to MOET)
- Stability fee collection (reserve withdrawal → stability fund)
- Governance operations (pause, unpause, add tokens, set rates, set curves, set oracle)
- Health computation (balance sheet construction, health factor)
- Deposit rate limiting
- Async position updates

**Impact**: Auditing any single concern requires reading and understanding the entire resource. A bug in fee collection could interact with reserve withdrawals in unexpected ways.

### 2. PoolState is a Flat Bag of Unrelated State

`PoolState` holds reserves, insurance fund, stability funds, position queues, position locks, token states, default token, and the position ID counter. Everything is gated behind a single `EImplementation` entitlement.

**Impact**: Any code path with `EImplementation` can withdraw from reserves, modify token state, deposit to the insurance fund, etc. There's no structural enforcement that, say, insurance collection only withdraws the calculated insurance amount.

### 3. Reserves Have No Access Control Boundary

Pool reserves (`@{Type: {FungibleToken.Vault}}`) are directly borrowable by any internal method via `state.borrowReserve(type)`. The same reference that the deposit path uses to add funds is the one that liquidation, fee collection, and withdrawals all use to remove funds.

**Impact**: It's difficult to verify that reserves are only withdrawn through sanctioned paths. An auditor must trace every call site of `borrowReserve` and `borrowOrCreateReserve` to confirm correctness.

### 4. InternalBalance Directly Mutates Global TokenState

`InternalBalance.recordDeposit()` and `recordWithdrawal()` take an `auth(EImplementation) &{TokenState}` reference and directly call `increaseCreditBalance`, `decreaseDebitBalance`, etc. This means a per-position struct has side effects on global accounting.

**Impact**: The coupling makes it hard to reason about what changes global state. A reader must understand that calling `position.borrowBalance(type)!.recordDeposit(...)` not only changes the position's balance but also the pool's total credit/debit balances, which in turn triggers interest rate recalculation.

### 5. Duplicated Health/Balance Sheet Logic

The code itself notes (line 73 of FlowALPv0): *"this logic partly duplicates FlowALPModels.BalanceSheet construction in _getUpdatedBalanceSheet"*. The `maxWithdraw` function at the contract level and `_getUpdatedBalanceSheet` inside Pool both iterate over position balances to compute effective collateral/debt, but use different code paths.

Similarly, `TokenSnapshot` creation is duplicated across `buildTokenSnapshot`, `buildPositionView`, `availableBalance`, and the contract-level `maxWithdraw`.

### 6. Fee Collection Interleaved with Core Lending

Insurance and stability fee collection (`_collectInsurance`, `_collectStability`, `updateInterestRatesAndCollectInsurance`, `updateInterestRatesAndCollectStability`) are methods on the Pool that directly withdraw from reserves and interact with external DEX swappers.

**Impact**: Fee collection failure modes (insufficient reserves, DEX price deviation) can potentially affect core lending operations if called in the wrong sequence.

### 7. PoolConfig Stores Risk Factors Separately from TokenState

Collateral factors and borrow factors live in `PoolConfig` (as `{Type: UFix64}` maps), while everything else about a token (interest curves, deposit limits, insurance rates) lives in `TokenState`. This split means building a `TokenSnapshot` requires reading from both `PoolConfig` and `TokenState`.

### 8. Single Entitlement for All Internal Operations

`EImplementation` gates everything from "set position lock" to "withdraw from reserves" to "modify interest curves". There's no way to grant partial internal access.

---

## Proposed Architecture

### Overview: Decompose into Modules with Narrow APIs

The core idea: replace the monolithic Pool with a **coordinator** that delegates to specialized **modules**, each with its own resource interface, invariants, and access control.

```
                    ┌─────────────────┐
                    │  Pool (thin      │  ← coordinates modules; no direct state
                    │  coordinator)    │
                    └──────┬──────────┘
          ┌────────────┬───┴────┬─────────────┬──────────────┐
          ▼            ▼        ▼             ▼              ▼
   ┌────────────┐ ┌────────┐ ┌──────────┐ ┌───────────┐ ┌──────────┐
   │ Reserve    │ │ Token  │ │ Position │ │ Fee       │ │Liquidation│
   │ Vault Mgr  │ │ Ledger │ │ Registry │ │ Collector │ │ Engine   │
   └────────────┘ └────────┘ └──────────┘ └───────────┘ └──────────┘
```

### Module 1: ReserveVaultManager

**Responsibility**: Sole custodian of FungibleToken vaults. Provides typed withdrawal functions that make the intent and authorization explicit.

**Key invariant**: Every vault withdrawal is through a purpose-specific function, making it trivially auditable.

**Interface**: See `cadence/contracts/proposals/ReserveVaultManager.cdc`

### Module 2: TokenLedger

**Responsibility**: Per-token accounting — interest indices, total credit/debit balances, interest curve, deposit capacity. Replaces the `TokenState` portion of `PoolState`.

**Key change**: `recordDeposit`/`recordWithdrawal` return an `EffectsDelta` struct instead of directly mutating global state. The caller (Pool coordinator) applies effects explicitly.

**Interface**: See `cadence/contracts/proposals/TokenLedger.cdc`

### Module 3: PositionRegistry

**Responsibility**: Per-position balance tracking, health parameters, queued deposits, position locks. Replaces the `positions` dictionary and position-related fields of `PoolState`.

**Key change**: Position balance mutations return descriptive effect objects rather than having side effects on global state.

**Interface**: See `cadence/contracts/proposals/PositionRegistry.cdc`

### Module 4: FeeCollector

**Responsibility**: Insurance and stability fee calculation and collection. Extracted from Pool to isolate fee logic and its interaction with reserves.

**Key change**: FeeCollector computes fee amounts and returns them; the coordinator orchestrates the actual vault withdrawal and deposit through ReserveVaultManager.

**Interface**: See `cadence/contracts/proposals/FeeCollector.cdc`

### Module 5: LiquidationEngine

**Responsibility**: Liquidation validation, DEX price comparison, and execution coordination. Extracted from the 100+ line `manualLiquidation` method.

**Key change**: Validation is separated from execution. The engine validates and returns a `LiquidationPlan` that the coordinator executes.

**Interface**: See `cadence/contracts/proposals/LiquidationEngine.cdc`

---

## Data Model Changes

### 1. Split PoolState into Purpose-Specific State Containers

**Before**: One `PoolState` resource with everything.

**After**:
- `ReserveVaultManager` — vault storage, purpose-specific withdrawals
- `TokenLedger` — `{Type: TokenState}`, interest accounting
- `PositionRegistry` — `{UInt64: InternalPosition}`, locks, update queue
- `FeeState` — insurance fund, stability funds (within `FeeCollector`)

### 2. Colocate Risk Factors with TokenState

**Before**: `collateralFactor` and `borrowFactor` in `PoolConfig`, everything else in `TokenState`.

**After**: Each `TokenState` includes its own `RiskParams`. Building a `TokenSnapshot` only requires one source of truth per token.

### 3. Effects-Based Balance Mutations

**Before**: `InternalBalance.recordDeposit(amount, tokenState)` directly mutates `tokenState`.

**After**: `TokenLedger.applyDeposit(tokenType, positionBalance, amount)` returns a `BalanceEffect` describing what changed. The coordinator applies these effects, making data flow explicit and testable.

```
// Before (hidden side effects):
position.borrowBalance(type)!.recordDeposit(amount: ..., tokenState: tokenState)

// After (explicit effects):
let effect = tokenLedger.computeDepositEffect(type, balance, amount)
tokenLedger.applyEffect(effect)
positionRegistry.updateBalance(pid, type, effect.newBalance)
```

### 4. Centralize TokenSnapshot Construction

**Before**: Built ad-hoc in 4+ places with slightly different code paths.

**After**: Single `tokenLedger.snapshot(type, riskParams, oraclePrice)` factory.

### 5. Fine-Grained Entitlements

**Before**: Single `EImplementation` for all internal operations.

**After**:
- `EReserveDeposit` / `EReserveWithdraw` — reserve vault operations
- `ETokenAccounting` — interest index and balance updates
- `EPositionMutation` — position balance changes
- `EFeeCollection` — fee calculation and collection
- `EGovernance` — (already exists, unchanged)

---

## Migration Strategy

These changes are *interface-level* — the underlying math and business logic remain the same. A phased migration could be:

1. **Phase 1**: Extract `ReserveVaultManager` from `PoolState`. This is the highest-value change (auditability of fund flows) and has the smallest blast radius.
2. **Phase 2**: Colocate risk factors with `TokenState`; centralize `TokenSnapshot` construction.
3. **Phase 3**: Extract `FeeCollector` and `LiquidationEngine`.
4. **Phase 4**: Switch to effects-based balance mutations.
5. **Phase 5**: Extract `PositionRegistry` and introduce fine-grained entitlements.

Each phase can be validated independently against existing tests.

---

## Files in this PR

- `ARCHITECTURE_REVIEW.md` — this document
- `cadence/contracts/proposals/ReserveVaultManager.cdc` — reserve vault interface
- `cadence/contracts/proposals/TokenLedger.cdc` — token-level accounting interface
- `cadence/contracts/proposals/PositionRegistry.cdc` — position management interface
- `cadence/contracts/proposals/FeeCollector.cdc` — fee collection interface
- `cadence/contracts/proposals/LiquidationEngine.cdc` — liquidation engine interface
- `cadence/contracts/proposals/PoolCoordinator.cdc` — thin coordinator showing how modules compose
