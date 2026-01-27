## FlowVaults Protocol — Production Liquidation Mechanism (DEX + Keeper + Auto)

### Objectives
- **Safety**: Permissionless, incentive-aligned liquidations that reliably resolve undercollateralized positions.
- **Coverage**: Dual paths — a direct repay-for-seize (keeper provides debt tokens) and a protocol-executed DEX path — plus an automatic DEX liquidation scheduler; no auction fallback.
- **Determinism**: Predictable math, oracle guards, and invariant checks.
- **Observability**: Rich events and view endpoints for keepers/frontends.

### Current foundations (in contract)
- **Risk math**: `healthFactor`, `effectiveCollateral`, `effectiveDebt`, per-token factors; `RiskParams` includes `liquidationBonus`.
- **Position config**: `InternalPosition` has `minHealth`, `targetHealth`, `maxHealth`, optional `topUpSource` and `drawDownSink`.
- **Oracle connectors**: `DeFiActions.PriceOracle` (Band Oracle impl supports staleness checks).

### Out-of-scope for this phase
- Multi-oracle medianization (can be added later).
- Insurance module for bad debt (can be added later, we expose hooks).

## Architecture

### Liquidation paths
- **Permissionless repay-for-seize (Keeper)**: A keeper repays the borrower’s debt and receives collateral with a bonus. Only the exact amount needed to reach the liquidation target health is used; any excess allowance is ignored.
- **Protocol-executed DEX**: Protocol seizes collateral, swaps via allowlisted DEX connector into debt asset, repays debt, and returns any remainder appropriately.

### Routing policy (DEX-first with keeper override)
1) Attempt `topUpSource` pull if present to restore health above the trigger (≥ 1.0).
2) If still unhealthy and outside warm-up: compute the DEX route and quote the effective collateral-per-debt price.
3) If a keeper presents an offer that is strictly better than the DEX route (i.e., requires less collateral per unit of debt repaid), route to keeper; otherwise execute via DEX.
4) Additionally, run an automatic DEX liquidation on a timer (or keeper-triggered automation) so that positions are liquidated even without explicit keeper participation, subject to oracle/DEX deviation guards.

## Governance parameters
- **Per-token (or global defaults)**
  - **collateralFactor** (exists)
  - **borrowFactor** (exists)
  - **liquidationBonus** (exists; percent added to seize quote)
  - **twapWindowSec**, **maxDeviationBps** (oracle guards)
  - **dustThresholdCredit**, **dustThresholdDebt**
- **Global**
  - **liquidationTriggerHF** = 1.0e18 (health strictly below this triggers liquidation; constant)
  - **liquidationTargetHF** (e.g., 1.05e18 or 1.10e18; exact health to reach post-liquidation)
  - **dexMaxSlippageBps**, **dexMaxRouteHops**
  - **dexOracleDeviationBps** (max allowed deviation between oracle price and DEX mid/quote)
  - **fees**: `protocolLiquidationFeeBps`, `keeperBountyBps`, `feeSink`
  - **connector allowlists**: `allowedSwappers`, `allowedOracles` (by component ID)
  - **circuit breakers**: `liquidationsPaused`, `liquidationWarmupSec` (warm-up delay after unpause when liquidations remain disabled)
  - **position health spacing** (validation rule): enforce `1.0 < min < target < max` with minimum spacing (e.g., ≥ 5% between bounds) for user-configured thresholds; not used by liquidation.

### Storage additions
- **`liquidationParams`** struct stored in pool.
- **Connector allowlists** and **fee sink** capability path.
- **`lastUnpausedAt: UInt64?`** to compute warm-up window (`liquidationWarmupSec`).

### Events
- **LiquidationParamsUpdated(poolUUID, targetHF, warmupSec, protocolFeeBps)**
- **LiquidationsPaused(by)** / **LiquidationsUnpaused(by, warmupEndsAt)**
- **LiquidationExecuted**(pid, liquidator, debtType, repayAmount, seizeType, seizeAmount, bonusBps, newHF)
- **LiquidationExecutedViaDex**(pid, seizeType, seized, debtType, repaid, slippageBps, newHF)
- **AutoLiquidationExecuted**(pid, route, debtType, repaid, seizeType, seized, newHF)
- **BadDebtWrittenOff**(pid, shortfall)

## Math and quoting (pure helpers)
- **Eligibility**: `health(view) < liquidationThresholdHF`.
- **Required repay to reach target**:
  - Compute the exact repay needed to move `health` to `liquidationTargetHF` given current snapshots.
  - If a keeper supplies more than required, only the required amount is used.
- **Seize for repay** (single collateral type):
  - Let `R = repayTrueAmount` in debt token, `P_d = price(debt)`, `P_c = price(collateral)`, `BF = borrowFactor(debt)`, `CF = collateralFactor(collateral)`, `LB = (1 + liquidationBonus)`.
  - Debt value basis = `(R * P_d) / BF`.
  - Seize amount = `DebtValue * LB / (P_c * CF)`.
- **Collateral selection**: choose collateral with highest effective value and available balance, unless a hint is provided.
- **Quote**: `quoteLiquidation(pid, debtType, seizeType?) -> {requiredRepay, seizeType, seizeAmount, newHF, route=Keeper|DEX}` including DEX-vs-keeper price comparison when keeper input is provided.

## Entrypoints (new public API)
- **View**
  - `isLiquidatable(pid) -> Bool`
  - `quoteLiquidation(pid, debtType, seizeType?) -> Quote`
  - `getLiquidationParams() -> LiquidationParams`
- **Permissionless actions**
  - `liquidateRepayForSeize(pid, debtType, maxRepayAmount, seizeType, minSeizeAmount)` (requires `maxRepayAmount ≥ requiredRepay`)
  - `autoLiquidate(pid, debtType, seizeTypeHint?, routeParams?)` (DEX path; callable by any keeper/cron executor)
- **Keeper/governance**
  - `liquidateViaDex(pid, debtType, seizeType, maxSeizeAmount, minRepayAmount, routeParams)`
  - `setLiquidationParams(params)`
  - `setConnectorAllowlists(swappers, oracles)`
  - `setFeeSink(sink)`
  - `pauseLiquidations(flag)`

## Execution flows

### Repay-for-seize (permissionless)
- Preconditions: liquidations not paused; past warm-up if recently unpaused; fresh indices for involved tokens; oracle staleness/deviation checks incl. DEX-vs-oracle deviation; `health < 1.0e18`.
- Steps:
  - Compute `requiredRepay` to reach `liquidationTargetHF`.
  - Require `maxRepayAmount ≥ requiredRepay`; transfer exactly `requiredRepay` from keeper; reduce position debt.
  - Compute `seizeAmount` with bonus; withdraw from position’s collateral; transfer to liquidator.
  - Apply fees/bounties from seized amount if configured; emit `LiquidationExecuted`.
- Postconditions: health increases; no negative balances; dust rules applied.

### Via DEX (protocol executes swap)
- Preconditions: same as above + swapper allowlisted + slippage bounds + DEX-vs-oracle deviation within `dexOracleDeviationBps`.
- Steps:
  - Seize up to `maxSeizeAmount` collateral to an internal temporary vault.
  - Swap seized collateral → debt token via `SwapConnectors.Swapper` with `minOut` based on slippage.
  - Repay debt with swap output; handle any leftover collateral (return to position or fees/sink per params).
  - Emit `LiquidationExecutedViaDex`.
- Security: snapshot → seize → external call → state mutate → emit; never pass borrower’s resources directly out.

### Auto liquidation (DEX timer)
- A scheduled or keeper-triggered automation repeatedly scans for undercollateralized positions and calls `autoLiquidate` using the DEX path, subject to the same oracle/DEX deviation and warm-up rules.
- Events: `AutoLiquidationExecuted` per position.

## Oracle safety and indices
- Use oracle with `staleThreshold`, per-token TWAP window, and `maxDeviationBps` guard vs last snapshot.
- Additionally enforce `dexOracleDeviationBps`: the DEX spot/TWAP price used for liquidation must be within this deviation vs oracle price, else revert.
- Accrue interest indices for involved tokens on-demand before quoting/execution.

## Invariants and safety checks
- Liquidation only when `health < threshold` and not paused.
- Post-liquidation: `health ≥ pre.health`.
- Balances never negative; dust thresholds applied.
- Fees ≤ seized amount; fee sink receives expected amount.
- Throttles: per-tx close factor, optional per-block liquidation cap, single active auction per pid.

## Scripts and transactions to add
- Scripts: `quote_liquidation.cdc`, `get_liquidation_params.cdc`.
- Transactions: `liquidate_repay_for_seize.cdc`, `liquidate_via_dex.cdc`, `auto_liquidate.cdc`.
- Governance tx: `set_liquidation_params.cdc`, `allow_swapper.cdc`, `pause_liquidations.cdc`.

## Testing strategy
- Unit (pure math): seize calculation vectors; HF monotonic increase on liquidation; close-factor clamping; rounding bias toward protocol.
- Scenarios: price drop → repay-for-seize; DEX route vs keeper offer routing; stale oracle rejection; DEX-vs-oracle deviation rejection; warm-up blocking; top-up source prevents liquidation; bad-debt write-off path.
- Fuzz/property: random portfolios and prices; repeated partial liquidations; assert invariants each step.

## Rollout phases
- **Phase 1**: Params (incl. warm-up, target HF), view quotes, `liquidateRepayForSeize` + tests/events.
- **Phase 2**: `liquidateViaDex` with an allowlisted swapper + slippage/deviation guards + tests.
- **Phase 3**: Auto liquidation scheduler + keeper example + monitoring dashboards.
- **Phase 4**: Security review, gas profiling, parameter calibration; optional insurance fund integration.

## Open questions
- Single-asset seize per call vs multi-asset? (recommend single per call)
- Default `liquidationTargetHF` (1.05 vs 1.10) and warm-up duration defaults
- Keeper offer format standardization for price comparison (quote units)
- Reserve/insurance module hookup for bad debt.

## References
- High-level design (Notion): https://www.notion.so/Liquidation-Mechanism-in-FlowVaults-23a9c94cfb9c8087bee9d8e99045b3d9
- Implementation doc (this branch): https://github.com/onflow/FlowCreditMarket/blob/feature/liquidation-mechanism/LIQUIDATION_MECHANISM_DESIGN.md

## Liquidation policy (Phase 1)
- **Target health factor (HF):** `liquidationTargetHF = 1.05e24`.
- **Trigger condition:** Liquidation is only allowed when current HF < 1.0e24.
- **Quote behavior (`quoteLiquidation`):**
  - **If feasible:** Return the unique pair `(requiredRepay, seizeAmount)` that moves the position to HF ≈ `liquidationTargetHF` using the minimal necessary repayment and collateral seize.
  - **If infeasible (insolvency):** Return the pair that maximizes HF subject to `seizeAmount ≤ availableCollateral`. If reaching the target is not possible but solvency is, the quote should move HF to ≥ 1.0e24 (as close to target as allowed). If even solvency is not achievable, the quote must strictly improve HF while remaining < 1.0e24. Do not exceed available collateral.
  - **No over-reward:** The quote never recommends seizing more collateral than required by the target (or insolvency boundary). Extra repayment must not increase seized collateral.
  - **Monotonicity:** As price worsens, `requiredRepay` must not decrease. As price improves, `requiredRepay` must not increase (for the same state).
  - **Rounding:** Round conservatively so post-quote execution is not below target due to rounding; small “at or above target” tolerance is acceptable.
- **Execution behavior (`liquidateRepayForSeize`):**
  - Uses the quote and takes **exactly** `requiredRepay` from the passed-in vault; if more is provided, the excess is returned/refunded to the caller.
  - Sends **exactly** `seizeAmount` collateral to the liquidator; never more.
  - Enforce slippage guards: `maxRepayAmount ≥ requiredRepay` and `minSeizeAmount ≤ seizeAmount`, else revert.
  - Multiple liquidations can occur over time, but each call performs a single exact-to-quote step. No “extra repay for extra seize.”

### Insolvency redemption (borrower path)
- **Repay-all-and-redeem:** The borrower must always be able to repay all outstanding debt and fully redeem their collateral in one operation, regardless of HF (including when HF < 1.0e24). This closes the position and returns all collateral to the borrower.
- **Partial borrower repayments:** Borrowers can partially repay debt via normal repay flows; collateral withdrawals remain gated by the health check. The effective collateral-to-debt exchange rate is determined by risk parameters and prices, not by discretionary ratios.

### Typical insolvency scenarios
- **Missed/late liquidation:** Automation or keepers fail to liquidate promptly after HF dips below 1.0, allowing interest accrual or price drift to deepen undercollateralization.
- **Sharp price gap:** A sudden oracle price drop (or market gap) pushes HF far below 1.0 faster than liquidation can be executed.
- **Route guards:** DEX-vs-oracle deviation guard or slippage limits temporarily block the DEX route; HF may worsen until conditions normalize or a keeper route executes.

### Partial-to-above-one policy
- When `liquidationTargetHF` cannot be reached due to constraints, but HF ≥ 1.0 is reachable, liquidations should proceed to bring HF above 1.0 immediately rather than waiting to hit 1.05 later. Subsequent liquidations can finish the move to target as conditions allow.

## Acceptance criteria
- **Feasible cases:** After execution, `newHF` is ≥ `liquidationTargetHF - ε` (tiny tolerance for rounding) and ≈ target.
- **Insolvent cases:** After execution, `newHF` is strictly improved compared to pre-liquidation HF. If the target is unreachable but solvency is, `newHF ≥ 1.0e24`. If even solvency is unreachable, `newHF < 1.0e24` but greater than pre-HF.
- **No over-repay/over-seize:** Sending a larger vault must not increase `seizeAmount`; the contract only consumes `requiredRepay`.
- **Slippage respected:** Transactions revert if `maxRepayAmount` < `requiredRepay` or `minSeizeAmount` > `seizeAmount`.

## What needs to be fixed/verified
- **Config**
  - Verify `liquidationTargetHF` is 1.05e24 and exposed via `get_liquidation_params.cdc`.
- **Contract**
  - Ensure `quoteLiquidation`:
    - Solves to target when feasible; otherwise returns boundary solution that maximizes HF under `seize ≤ availableCollateral`.
    - Rounds conservatively (post-exec HF not below target when feasible).
    - Respects monotonicity vs price.
  - Ensure `liquidateRepayForSeize`:
    - Consumes exactly `requiredRepay` and seizes exactly `seizeAmount`.
    - Refunds any excess funds passed in.
    - Enforces slippage guards and rejects partial repayments that do not meet the quoted requirement.
- **Tests**
  - Update insolvency test:
    - Expect `requiredRepay > 0`, `seizeAmount > 0`.
    - Do not require “full seize” by default; instead require `newHF` > pre-HF and not above target; if the scenario is known infeasible, allow `newHF < 1.0e24`.
  - Update multi-liquidation test:
    - Ensure initial price produces HF < 1.0.
    - After one liquidation, assert `newHF` ≥ target (feasible case); if you want multi-step, drop price further and liquidate again.
  - Add an “overpay attempt” test:
    - Pass `maxRepayAmount` > `requiredRepay` and assert actual repay equals `requiredRepay` and `seizeAmount` unchanged.
  - Add a slippage failure test:
    - `maxRepayAmount < requiredRepay` → revert; `minSeizeAmount > seizeAmount` → revert.
  - Add rounding guard test:
    - Feasible case should not end below target due to rounding.

