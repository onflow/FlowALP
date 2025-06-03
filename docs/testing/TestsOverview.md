# TidalProtocol — Functional Test-Suite Blueprint (Updated)

| ID  | Capability / Invariant | Scenario to simulate | Expected assertions |
|-----|------------------------|----------------------|---------------------|
| **A Core Vault behaviour** |
| A-1 | Deposit → Withdraw symmetry | Create `FlowVault` with **10 FLOW** → `Pool.deposit(pid, vault)` → immediately withdraw same amount | `withdraw()` returns **10 FLOW** · reserves unchanged · `positionHealth == 1` |
| A-2 | Health check prevents unsafe withdrawal | Start with **➕ 5 FLOW** collateral; try to withdraw **8 FLOW** | Transaction reverts with "Position is overdrawn" |
| A-3 | Direction flip **Debit → Credit** | Create position with debt, then deposit enough to flip to credit | Position direction changes · balances update correctly |
| **B Interest-index mechanics** |
| B-1 | Interest index initialization | Check initial state of TokenState | `creditInterestIndex == 10^16` · `debitInterestIndex == 10^16` |
| B-2 | Interest rate calculation | Set up position with credit and debit balances | `updateInterestRates()` calculates rates based on utilization |
| B-3 | Scaled balance conversion | Test `scaledBalanceToTrueBalance` and reverse | Conversions are symmetric within precision limits |
| **C Position health & liquidation** |
| C-1 | Healthy position | Create position with only credit balance | `positionHealth() == 1.0` (no debt means healthy) |
| C-2 | Position health calculation | Create position with credit and debit | Health = effectiveCollateral / totalDebt |
| C-3 | Withdrawal blocked when unhealthy | Try to withdraw that would make position unhealthy | Transaction reverts with "Position is overdrawn" |
| **D Interest calculations** |
| D-1 | Per-second rate conversion | Test `perSecondInterestRate()` with 5% APY | Returns correct fixed-point multiplier |
| D-2 | Compound interest calculation | Test `compoundInterestIndex()` with various time periods | Correctly compounds interest over time |
| D-3 | Interest multiplication | Test `interestMul()` function | Handles fixed-point multiplication correctly |
| **E Token state management** |
| E-1 | Credit balance updates | Deposit funds and check TokenState | `totalCreditBalance` increases correctly |
| E-2 | Debit balance updates | Withdraw to create debt and check TokenState | `totalDebitBalance` increases correctly |
| E-3 | Balance direction flips | Test deposits/withdrawals that flip balance direction | TokenState tracks both credit and debit changes |
| **F Reserve management** |
| F-1 | Reserve balance tracking | Deposit and withdraw from pool | `reserveBalance()` matches expected amounts |
| F-2 | Multiple positions | Create multiple positions in same pool | Each position tracked independently |
| F-3 | Position ID generation | Create multiple positions | IDs increment sequentially from 0 |
| **G Access control & entitlements** |
| G-1 | Withdraw entitlement | Access vault withdrawal without entitlement | Operation requires `Withdraw` entitlement |
| G-2 | EPosition entitlement | Try to call pool functions without capability | Functions require proper entitlements |
| **H Edge-cases & precision** |
| H-1 | Zero amount validation | Try to deposit or withdraw 0 | Reverts with "amount must be positive" |
| H-2 | Small amount precision | Deposit very small amounts (0.00000001) | Handle precision limits gracefully |
| H-3 | Empty position operations | Withdraw from position with no balance | Appropriate error handling |

---

## Cadence Test-file Breakdown (Updated)

| File | Covers | Key Test Focus |
|------|--------|----------------|
| `core_vault_test.cdc` | A-series | Basic deposit/withdraw operations and health checks |
| `interest_mechanics_test.cdc` | B-series, D-series | Interest index calculations and rate conversions |
| `position_health_test.cdc` | C-series | Position health calculations and withdrawal restrictions |
| `token_state_test.cdc` | E-series | TokenState balance tracking and updates |
| `reserve_management_test.cdc` | F-series | Pool reserves and multi-position handling |
| `access_control_test.cdc` | G-series | Entitlement enforcement |
| `edge_cases_test.cdc` | H-series | Edge cases and precision limits |

## Notes on Contract Limitations

The current TidalProtocol contract implementation:
- Only supports FlowVault tokens (no multi-token support implemented)
- Uses SimpleInterestCurve that always returns 0% interest
- Has dummy Sink/Source implementations that don't do anything
- Lacks deposit queue, rate limiting, and governance features
- No oracle integration for price feeds
- Liquidation thresholds are set but no liquidation mechanism exists

Tests should focus on what the contract actually implements rather than the full vision described in the original blueprint.