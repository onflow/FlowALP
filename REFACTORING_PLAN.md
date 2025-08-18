# TidalProtocol Refactoring Plan - Health/Withdraw/Liquidation Vertical Slice

## 1. Refactoring Plan ("vertical-slice" focus: health/withdraw/liquidation)

• Extract view-only value types  
  – `RiskParams` (collateralFactor, borrowFactor, liquidationBonus)  
  – `TokenSnapshot` (price, creditIndex, debitIndex, timestamp)  
  – `PositionView` (balances[], effectiveCollateral, effectiveDebt, health)

• Pure helpers (no storage/oracle/time)  
  – `healthFactor(view: PositionView): UInt256`  
  – `effectiveCollateral(balance, price, factor)`  
  – `effectiveDebt(balance, price, factor)`  
  – `maxWithdraw(view, withdrawPrice, withdrawFactors, targetHealth)`  
  – `requiredTopUp(view, depositPrice, depositFactors, targetHealth)`  
  – `interestAccrued(indexOld, ratePerSecond, dtSec)`  
  – `updateIndex(oldIndex, ratePerSecond, dtSec)`

• Queries (read only)  
  – `buildPositionView(pid)` (loads state, builds pure struct, returns)  
  – `getAvailableBalance(pid, t, pullTopUp)` now: build view + call `maxWithdraw`

• Commands (imperative shell)  
  – `applyDeposit(pid, vault, pushFlag)`  
  – `applyWithdraw(pid, amount, type, pullFlag)` (uses `maxWithdraw` for validation)  
  – `applyAccrual(pid, token)` (reads time, calls pure `updateIndex`, writes)  
  – `applyLiquidation(pid, repayVault)` (calls pure helpers to compute seize, etc.)

• Invariants encoded with pre/post‐conditions  
  – Balances ≥ 0 – no over/underflow  
  – After command, `health ≥ minHealth` (unless liquidation)  
  – Interest accrual never decreases total debt when rates ≥ 0  
  – Liquidation rejected when `health ≥ 1e18`

• Mutable pieces that stay in storage  
  – `Pool.globalLedger[..]` indexes, `InternalPosition.balances`, queues/reserves

## 2. Code (only the slice; other commands stubbed with TODO)

```cadence
// VALUE TYPES / VIEWS --------------------------------------------------------

access(all) struct RiskParams {
    access(all) let collateralFactor: UInt256  // e18
    access(all) let borrowFactor: UInt256      // e18
    access(all) let liquidationBonus: UInt256  // e18  (e.g. 1.05e18 = +5%)
    init(cf: UInt256, bf: UInt256, lb: UInt256) {
        self.collateralFactor = cf
        self.borrowFactor = bf
        self.liquidationBonus = lb
    }
}

/// Immutable snapshot of token-level data required for math
access(all) struct TokenSnapshot {
    access(all) let price: UInt256          // defaultToken decimals, e18 fixed-point
    access(all) let creditIndex: UInt256    // e18
    access(all) let debitIndex: UInt256     // e18
    access(all) let risk: RiskParams
    init(price: UInt256, credit: UInt256, debit: UInt256, risk: RiskParams) {
        self.price = price
        self.creditIndex = credit
        self.debitIndex = debit
        self.risk = risk
    }
}

/// Copy-only representation of a position used by pure math
access(all) struct PositionView {
    access(all) let balances: {Type: TidalProtocol.InternalBalance}     // copy
    access(all) let snapshots: {Type: TokenSnapshot}
    access(all) let defaultToken: Type
    access(all) let minHealth: UInt256
    access(all) let maxHealth: UInt256
    init(balances: {Type: TidalProtocol.InternalBalance},
         snapshots: {Type: TokenSnapshot},
         def: Type,
         min: UInt256,
         max: UInt256) {
        self.balances = balances
        self.snapshots = snapshots
        self.defaultToken = def
        self.minHealth = min
        self.maxHealth = max
    }
}

// PURE HELPERS ----------------------------------------------------------------

access(all) fun effectiveCollateral(credit: UInt256, snap: TokenSnapshot): UInt256 {
    return TidalProtocolUtils.mul(
        TidalProtocolUtils.mul(credit, snap.price),
        snap.risk.collateralFactor)
}

access(all) fun effectiveDebt(debit: UInt256, snap: TokenSnapshot): UInt256 {
    return TidalProtocolUtils.div(
        TidalProtocolUtils.mul(debit, snap.price),
        snap.risk.borrowFactor)
}

/// Computes health = effColl / effDebt  (∞ when debt==0)
access(all) fun healthFactor(view: PositionView): UInt256 {
    var coll: UInt256 = 0
    var debt: UInt256 = 0
    for t in view.balances.keys {
        let b = view.balances[t]!
        let snap = view.snapshots[t]!
        if b.direction == TidalProtocol.BalanceDirection.Credit {
            let trueBal = TidalProtocol.scaledBalanceToTrueBalance(b.scaledBalance,
                              interestIndex: snap.creditIndex)
            coll = coll + effectiveCollateral(trueBal, snap)
        } else {
            let trueBal = TidalProtocol.scaledBalanceToTrueBalance(b.scaledBalance,
                              interestIndex: snap.debitIndex)
            debt = debt + effectiveDebt(trueBal, snap)
        }
    }
    return TidalProtocol.healthComputation(
        effectiveCollateral: coll,
        effectiveDebt: debt)
}

/// Amount of `withdrawSnap` token that can be withdrawn while staying ≥ targetHealth
access(all) fun maxWithdraw(
    view: PositionView,
    withdrawSnap: TokenSnapshot,
    withdrawBal: TidalProtocol.InternalBalance?,
    targetHealth: UInt256
): UInt256 {
    let preHealth = healthFactor(view: view)
    if preHealth <= targetHealth {
        return 0
    }

    // linear solve: find x such that newHealth == targetHealth
    var effColl: UInt256 = 0
    var effDebt: UInt256 = 0
    for t in view.balances.keys {
        let b = view.balances[t]!
        let snap = view.snapshots[t]!
        if b.direction == BalanceDirection.Credit {
            let trueBal = TidalProtocol.scaledBalanceToTrueBalance(b.scaledBalance,
                              interestIndex: snap.creditIndex)
            effColl = effColl + effectiveCollateral(trueBal, snap)
        } else {
            let trueBal = TidalProtocol.scaledBalanceToTrueBalance(b.scaledBalance,
                              interestIndex: snap.debitIndex)
            effDebt = effDebt + effectiveDebt(trueBal, snap)
        }
    }

    let cf = withdrawSnap.risk.collateralFactor
    let bf = withdrawSnap.risk.borrowFactor
    if withdrawBal == nil || withdrawBal!.direction == TidalProtocol.BalanceDirection.Debit {
        // withdrawing increases debt
        // solve: (effColl) / (effDebt + ΔDebt) = targetHealth
        let numerator = effColl
        let denominatorTarget = TidalProtocolUtils.div(numerator, targetHealth)
        let ΔDebt = denominatorTarget > effDebt ? denominatorTarget - effDebt : 0 as UInt256
        let tokens = TidalProtocolUtils.div(
            TidalProtocolUtils.mul(ΔDebt, bf),
            withdrawSnap.price)
        return tokens
    } else {
        // withdrawing reduces collateral
        let trueBal = TidalProtocol.scaledBalanceToTrueBalance(withdrawBal!.scaledBalance,
                      interestIndex: withdrawSnap.creditIndex)
        let maxPossible = trueBal
        // solve: (effColl - ΔColl) / effDebt = targetHealth
        let requiredColl = TidalProtocolUtils.mul(effDebt, targetHealth)
        if effColl <= requiredColl {
            return 0
        }
        let ΔCollEff = effColl - requiredColl
        let ΔTokens = TidalProtocolUtils.div(
            TidalProtocolUtils.div(ΔCollEff, cf),
            withdrawSnap.price)
        return ΔTokens > maxPossible ? maxPossible : ΔTokens
    }
}

// similar pure helper `requiredTopUp` omitted for brevity …

// READ-ONLY QUERY -----------------------------------------------------------

access(all) fun buildPositionView(pid: UInt64): TidalProtocol.PositionView {
    let position = self._borrowPosition(pid: pid)
    let snaps: {Type: TokenSnapshot} = {}
    let balancesCopy: {Type: TidalProtocol.InternalBalance} = {}
    for t in position.balances.keys {
        let bal = position.balances[t]!
        balancesCopy[t] = TidalProtocol.InternalBalance(
            direction: bal.direction,
            scaledBalance: bal.scaledBalance
        )
        let ts = self._borrowUpdatedTokenState(type: t)
        snaps[t] = TokenSnapshot(
            price: TidalProtocolUtils.ufix64ToUInt256(self.priceOracle.price(ofToken: t)!, decimals: 18),
            credit: ts.creditInterestIndex,
            debit: ts.debitInterestIndex,
            risk: RiskParams(
                cf: TidalProtocolUtils.ufix64ToUInt256(self.collateralFactor[t]!, decimals: 18),
                bf: TidalProtocolUtils.ufix64ToUInt256(self.borrowFactor[t]!, decimals: 18),
                lb: TidalProtocolUtils.e18 + 50_000_000_000_000_000
            )
        )
    }
    return TidalProtocol.PositionView(
        balances: balancesCopy,
        snapshots: snaps,
        def: self.defaultToken,
        min: position.minHealth,
        max: position.maxHealth
    )
}

// availableBalance: preserve top-up path; use pure helpers otherwise
access(all) fun availableBalance(pid: UInt64, type: Type, pullFromTopUpSource: Bool): UFix64 {
    let position = self._borrowPosition(pid: pid)
    if pullFromTopUpSource && position.topUpSource != nil {
        let sourceType = position.topUpSource!.getSourceType()
        let sourceAmount = position.topUpSource!.minimumAvailable()
        return self.fundsAvailableAboveTargetHealthAfterDepositing(
            pid: pid,
            withdrawType: type,
            targetHealth: position.minHealth,
            depositType: sourceType,
            depositAmount: sourceAmount
        )
    }
    let view = self.buildPositionView(pid: pid)
    let tokenState = self._borrowUpdatedTokenState(type: type)
    let snap = TokenSnapshot(
        price: TidalProtocolUtils.ufix64ToUInt256(self.priceOracle.price(ofToken: type)!, decimals: 18),
        credit: tokenState.creditInterestIndex,
        debit: tokenState.debitInterestIndex,
        risk: RiskParams(
            cf: TidalProtocolUtils.ufix64ToUInt256(self.collateralFactor[type]!, decimals: 18),
            bf: TidalProtocolUtils.ufix64ToUInt256(self.borrowFactor[type]!, decimals: 18),
            lb: TidalProtocolUtils.e18 + 50_000_000_000_000_000
        )
    )
    let withdrawBal = view.balances[type]
    let uintMax = maxWithdraw(
        view: view,
        withdrawSnap: snap,
        withdrawBal: withdrawBal,
        targetHealth: view.minHealth)
    return TidalProtocolUtils.uint256ToUFix64(uintMax, decimals: 18)
}

// MUTATING  COMMANDS  (imperative shell) -------------------------------------

access(EPosition) fun applyWithdraw(
    pid: UInt64,
    t: Type,
    amount: UFix64,
    pull: Bool
): @{FungibleToken.Vault} {
    pre {
        amount >= 0.0: "amount negative"
    }
    let uintAmount = TidalProtocolUtils.ufix64ToUInt256(amount, decimals: 18)

    // pure validation
    let view = self.buildPositionView(pid: pid)
    let snap = view.snapshots[t]!
    let bal = view.balances[t]
    let limit = maxWithdraw(
            view: view,
            withdrawSnap: snap,
            withdrawBal: bal,
            targetHealth: view.minHealth)
    assert(uintAmount <= limit, message: "Insufficient health for withdrawal")

    // imperative section – perform state changes
    let pool = self._borrowPosition(pid: pid)
    let tokenState = self._borrowUpdatedTokenState(type: t)
    if pool.balances[t] == nil {
        pool.balances[t] = InternalBalance()
    }
    pool.balances[t]!.recordWithdrawal(
        amount: uintAmount,
        tokenState: tokenState)

    let reserve = (&self.reserves[t] as auth(FungibleToken.Withdraw) &{FungibleToken.Vault})!
    let out <- reserve.withdraw(amount: amount)

    post {
        self.positionHealth(pid: pid) >= pool.minHealth:
            "post-health invariant broke"
    }
    emit Withdrawn(pid: pid, poolUUID: self.uuid, type: t.identifier, amount: amount, withdrawnUUID: out.uuid)
    return <- out
}

// other commands: applyDeposit, applyAccrual, applyLiquidation – outline TODO

```

## 3. Tests (scaffold – Flow test runner or Golang cadence-test)

```cadence
test fun healthFactor_edgeCases() {
    let zero = UInt256(0)
    let snap = TokenSnapshot(price: 1e18, credit: 1e18, debit: 1e18,
        risk: RiskParams(cf: 1e18, bf: 1e18, lb: 1e18))
    var balances: {Type: InternalBalance} = {}
    // zero debt & collateral
    let pv = PositionView(balances: balances, snapshots: {}, def: Type<@MOET.Vault>(), min: 1e18, max: 2e18)
    assert(healthFactor(view: pv) == zero, message: "zero health expected")
}

test fun interestAccrued_neverNegative() {
    let old = 1e18
    let rate = UInt64(1e18 + 1000)   // 0.000001% /s
    let newIdx = updateIndex(old, rate, 3600.0)
    assert(newIdx >= old, message: "accrual should not decrease")
}

// property-based example (pseudo)
property withdrawReducesCollateralNotDebt {
    // generate random position with credit balance
}

// scenario integration
scenario depositBorrowLiquidate {
    // 1. deposit X collateral
    // 2. borrow Y
    // 3. accrue interest 1 year
    // 4. drop price 50%, liquidate
}

```

## 4. Invariants (pre/post)

1. `balances[type].scaledBalance` ≥ 0 (pre & post every command)  
2. Position health ≥ minHealth after `applyDeposit`, `applyWithdraw`, `applyAccrual`  
3. Accrual: `totalDebitBalance` non-decreasing when `currentDebitRate ≥ 1e18`  
4. Liquidation pre: `health < 1e18`; post: `health ≥ pre.health`  
5. Withdraw limit enforced (`amount ≤ maxWithdraw`)  

## 5. Notes & Assumptions

• Only the withdraw/health slice fully refactored; similar pattern must be applied to deposit, accrual, liquidation.  
• `PositionView` uses copies of `InternalBalance` (safe because it's a `struct`).  
• Oracle price, time, and rates are still fetched in the shell; pure helpers receive those as inputs.  
• `RiskParams.liquidationBonus` hard-coded (+5%) until governance config added.  
• Rounding direction: helper functions biased toward protocol (i.e., borrower-unfavourable).  
• Future work: finish command set, migrate tests to cadence-test harness, move queue logic to separate service command.

## Questions  
• Should `depositRate` & queued deposits be enforced in pure layer too?  
• Is governance allowed to change risk params mid-block (race conditions)?

The pattern above demonstrates Functional-Core / Imperative-Shell, command–query separation, explicit invariants, and unit-testable pure math.

---

## 🚀 Full-Contract Exhaustive Refactor Plan (supersedes slice)

*The following pages integrate feedback and close all remaining gaps—deposit, accrual, liquidation, queue processing, governance, invariants, testing and security.*

### 0 Objectives
1. Deterministic pure core
2. Thin effectful shell
3. Command–query separation
4. Strong invariants (`pre`/`post` + property tests)
5. Complete unit / scenario / fuzz coverage

### 1 Phased Road-Map
| Phase | Outcome | Why? | How? | Where? |
| --- | --- | --- | --- | --- |
| P0 | Health / withdraw slice ✅ | Targets core, error-prone calcs like health (current: verbose loops in `positionHealth`). | Extract views and pure helpers; implement queries/commands for withdraw/health. | Replace `computeAvailableWithdrawal` and `positionHealth` with new funcs around line 800-1000. Add tests in `cadence/tests/position_health_test.cdc`. |
| P1 | Finish deposit · accrual · liquidation commands + helpers | Covers mutations with side effects (e.g., accrual mixes time/compounding). | Add pure funcs like `requiredTopUp`; implement commands with pre/post. | Update `depositAndPush`, `updateInterestIndices`, `liquidatePosition` sections (lines 500-700); new helpers in utils section. |
| P2 | Pure rate-limit & deposit-capacity maths | Simplifies rate updates (current: edges in `updateInterestRates`). | Pure funcs for rates/capacity; integrate into commands. | Refactor `updateInterestRates` (lines 300-350); add to `TidalMath.cdc` if separate. |
| P3 | Pure queue / async update processing | Addresses gas/scalability in queues (current: `positionsNeedingUpdates`). | Pure queue logic; batch processing in commands. | Update `processQueuedDeposits` and async funcs (lines 1200+); add batch limits. |
| P4 | Governance resource + capability rotation | Mitigates risks like mid-block changes (current: basic `EGovernance`). | New resource with rotation; snapshot params. | Add `Governance` resource (new section ~line 200); update setters like `setCollateralFactor`. |
| P5 | Fuzz harness, invariant dashboard, formal specs | Ensures robustness (current: no formal invariants). | Implement fuzz tests; document invariants. | New files in `cadence/tests/fuzz/`; add specs in comments or external docs. |

### 2 Design Highlights
• **Value-only types**: `RiskParams`, `TokenSnapshot`, `PositionView`, `PoolSnapshot`, `DepositQueueEntry`  
• **Pure helpers (TidalMath.cdc)**: `effectiveCollateral`, `effectiveDebt`, `healthFactor`, `maxBorrow`, `maxWithdraw`, `requiredTopUp`, `liquidationQuote`, `updateIndex`, `nextDepositCapacity`  
• **Queries**: build snapshots once, delegate to helpers  
• **Commands**: `applyDeposit`, `applyWithdraw`, `applyBorrow`, `applyRepay`, `applyAccrual`, `applyLiquidation`, `processQueuedDeposits`, `asyncUpdate`  
• **Governance**: new `Governance` resource + `RiskConfig`, `rotatePoolCap()`

### 3 Invariant Matrix
1. `scaledBalance ≥ 0`  
2. Position health ≥ minHealth post-command  
3. `totalCreditBalance / totalDebitBalance` match sum of true balances  
4. `depositCapacity ∈ [0, cap]`  
5. Indices & totalDebit non-decreasing when rate ≥ 1e18  
6. No duplicate `positionsNeedingUpdates`  
7. `version` strictly monotonic  
8. Liquidation allowed iff health < 1 · post ≥ pre  
9. Reserve balances equal net protocol true balance

### 4 Testing Strategy
* **Pure unit tests**: edge vectors + properties (`updateIndex↑`, round-trip balances, monotone quotes)  
* **Scenario tests**: 1) happy-path deposit→borrow→repay; 2) liquidation path; 3) queued deposit throttling  
* **Fuzz**: random command streams + governance flips, assert invariants every step

### 5 Security & Overflow
* `SafeUInt256` wrapper + `MAX_INDEX` guard (2^240-1)  
* Vault type validation on every resource move  
* Rounding biased borrower-unfavourable  
* Capability revocation on pool upgrade

### 6 Open Questions
* Block-level param changes—mitigate by snapshot `blockHeight`  
* Gas limits for `maxWithdraw` on many-token positions—profile after refactor  
* Formal spec scope—start with `healthFactor`, `liquidationQuote`, reserve invariants

---

_End of exhaustive plan.  Each phase will be implemented in dedicated PRs, accompanied by tests and documentation._

## Reasoning Behind the Refactor
### Why Refactor?
The current `TidalProtocol.cdc` (over 2000 lines) has monolithic functions that mix pure math (e.g., health calculations) with side effects (e.g., vault mutations, events), leading to hard-to-test code, duplication, and risks like overflows or invalid states. This refactor applies functional-core/imperative-shell principles to separate concerns, improve testability, enforce invariants, and address pain points like complex accrual logic and governance risks. It will make the contract more maintainable, secure, and scalable for features like multi-token positions and async updates.

### How Will Changes Be Made?
- **Core Pattern**: Extract immutable view structs (e.g., `PositionView`) and pure helpers (e.g., `healthFactor`) into a new `TidalMath.cdc` or inline utils. Commands (e.g., `applyWithdraw`) will build views, call pure funcs for validation, then perform mutations with pre/post conditions.
- **Phased Implementation**: Each phase in dedicated PRs to `cadence/contracts/TidalProtocol.cdc`, with tests in `cadence/tests/`. Use entitlements (e.g., `EImplementation`) for safe mutations. Profile gas and add SafeUInt256 for safety.
- **Testing**: Add unit tests for pure funcs, scenarios for commands, and fuzzing for invariants.
- **Migration**: For live deployment, add upgrade scripts to rotate capabilities without disrupting positions.

### Where Will Changes Be Made?
- **Pure Core**: New helpers in a dedicated section or file (e.g., lines 1000+ in TidalProtocol.cdc).
- **Commands/Queries**: Replace existing funcs (e.g., `availableBalance` becomes a query calling `buildPositionView` + `maxWithdraw`).
- **Storage**: Keep mutable fields (e.g., `globalLedger`, `positions`) but access via views.
- **Governance**: New `Governance` resource at top-level.