# AlpenFlow — Functional Test-Suite Blueprint

| ID  | Capability / Invariant | Scenario to simulate | Expected assertions |
|-----|------------------------|----------------------|---------------------|
| **A Core Vault behaviour** |
| A-1 | Deposit → Withdraw symmetry | Create `FlowVault` with **10 FLOW** → `Pool.deposit(pid, vault)` → immediately withdraw same amount | `withdraw()` returns **10 FLOW** · reserves unchanged · `positionHealth == 1` |
| A-2 | Direction flip **Credit → Debit** | Start with **➕ 5 FLOW** collateral; withdraw **8 FLOW** | Position becomes **Debit 3 FLOW** · `totalDebitBalance` increases · `positionHealth \< 1` |
| A-3 | Direction flip **Debit → Credit** | Start in **Debit 4 FLOW**; deposit **10 FLOW** | Ends in **Credit 6 FLOW** · credit & debit aggregates net to 0 |
| **B Interest-index mechanics** |
| B-1 | Accrual on suppliers | Deposit **100 FLOW** → advance block timestamp **1 year** at **5 % APY** | `scaledBalance × liquidityIndex ≈ 105 FLOW` (±1 sat) |
| B-2 | Accrual on borrowers | Borrow **50 FLOW** at **7 % APY** → advance **6 months** | Debt ≈ `50 × 1.035` |
| B-3 | Rate-change snapshot | Year starts at **5 %**; mid-year governor bumps to **8 %** | Index math equals piece-wise compounding |
| **C Position health & liquidation** |
| C-1 | Healthy position (HF ≥ 1) | **+100 FLOW** collateral & **–50 USDC** debt | `positionHealth > 1` |
| C-2 | Underwater position | Slash FLOW oracle price **–70 %** | `positionHealth < 1`; new borrow reverts |
| C-3 | Queue collateral counts | 20 FLOW in **deposit queue** · main collateral 0 · debt 15 FLOW | Health ≥ 1 even while queued |
| **D Rate-limited deposit queue** |
| D-1 | Throttle applies | TPS = 10 FLOW/s; after 1 s deposit **100 FLOW** | Only allocation (≈10) lands; 90 queued |
| D-2 | Scheduler clears queue | Advance 9 s; call `processQueue()` | Remaining 90 FLOW credited; queue empty |
| D-3 | Queue-first withdrawal | 50 FLOW queued + 10 FLOW main; withdraw 30 FLOW | 30 taken from queue · queue left 20 |
| **E Sink / Source hooks** |
| E-1 | Push to sink on surplus | Provide `StakeSink`; health = 2.0 | Excess FLOW pushed to sink; reserves ↓ |
| E-2 | Pull from source on shortfall | Provide `DummySource` (10 FLOW); slash price so HF \< 1; call `rebalance()` | Source supplies FLOW; health ≥ 1 |
| E-3 | Sink cap honoured | `minimumCapacity = 5`; try to push 8 | Only 5 accepted · 3 remain in pool |
| **F Governance / risk-module upgrades** |
| F-1 | Swap `InterestCurve` | Deploy `SimpleInterestCurve` then hot-swap to `AggressiveCurve` | `updateInterestRates()` uses new APY · indices stay continuous |
| **G Access control & entitlements** |
| G-1 | Withdraw entitlement | Call `reserveVault.withdraw` from account *without* `Withdraw` capability | Tx aborts |
| G-2 | Implementation entitlement | External account mutates `InternalBalance` | Tx aborts |
| **H Edge-cases & rounding** |
| H-1 | Zero amount | Deposit or withdraw 0 | Abort “amount must be positive” |
| H-2 | Max precision | Deposit `0.00000001` FLOW | Scaled math reversible within 1 sat |

---

## Cadence Test-file Breakdown

| File | Covers | Helpers / fixtures |
|------|--------|--------------------|
| `core_vault_test.cdc` | A-series | `newEmptyVault()`, `advanceTime()` |
| `interest_index_test.cdc` | B-series | `setAPY()`, `advanceTime()` |
| `health_liquidation_test.cdc` | C-series | Oracle mock contract |
| `deposit_queue_test.cdc` | D-series | `setTPS()`, `processQueue()` |
| `sink_source_test.cdc` | E-series | Dummy sink & source structs |
| `governance_upgrade_test.cdc` | F-series | Risk-module swap via governance cap |
| `access_control_test.cdc` | G-series | — |
| `edge_case_test.cdc` | H-series | — |