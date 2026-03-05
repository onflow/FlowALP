# FlowALP – Quantstamp Second Round Audit: Analysis & Response

> **Audit commit:** `abea0e2232f0b8cad6fdc46621c6beb7290b429c`
> **Current contract:** `FlowALPv0.cdc` (was `FlowALPv1.cdc` at audit time – renamed only)
> **Audit period:** 2026-02-11 to 2026-02-25
> **Auditors:** Yamen Merhi, Mostafa Yassin, Gereon Mendler (Quantstamp)
> **Status:** DRAFT – All findings unresolved per auditor

---

## How to use this document

For each finding, fill in:
- **Action**: `[ ] No Action` / `[ ] Code Changes` / `[ ] Documentation`
- **DRI**: directly responsible individual
- **Notes**: any context, links to PRs, etc.

---

# HIGH SEVERITY

---

## FLO-1 – Uncollected Protocol Fees Are Permanently Lost when Reserves Are Low

**Severity:** High | **File:** `FlowALPv0.cdc`

**Description:**
`_collectInsurance()` and `_collectStability()` cap the withdrawal at the available reserve balance when the reserve is short, then **unconditionally reset** `lastInsuranceCollectionTime` / `lastStabilityFeeCollectionTime`. The uncollected remainder is permanently forgotten – it belongs to neither the protocol nor the lenders.

**QS Recommendation:**
Introduce `pendingInsuranceFee` / `pendingStabilityFee` trackers in `TokenState`. During collection, add the newly calculated fee to the pending tracker, withdraw as much as the reserve allows, and subtract only the successfully withdrawn amount.

---

**Current code status (FlowALPv0.cdc):** ⚠️ **Still present.**
`_collectInsurance()` line 2123 caps to available balance (`amountToCollect = min(insuranceAmountUFix64, reserveVault.balance)`) then resets the timestamp at line 2138 regardless of whether the full amount was collected. Same pattern in `_collectStability()` lines 2175/2178. No `pendingInsuranceFee` variable exists.

### Claude

**Explanation:** When the protocol tries to collect its periodic fee but the reserve bucket doesn't have enough tokens to cover the full amount, it takes whatever is there and then resets the clock as if the full fee was paid. The shortfall just disappears — it's not owed to anyone anymore. So the protocol silently collects less than it's entitled to whenever reserves run low.

**Recommendation:** Fix this. The invariant violation is real – tokens accrued by the fee rate are deducted from lender credit rates but then vanish when reserves run dry. The QS fix (pending tracker) is exactly right. One additional note: the early-return cases (rate == 0, amount rounds to 0) that also reset the timestamp are fine, since no fee was ever owed in those cases. Only the partial-collection case (reserve < calculated fee) needs the pending tracker.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

## FLO-2 – `setInsuranceRate()` / `setStabilityFeeRate()` Retroactively Applies New Rates

**Severity:** High | **File:** `FlowALPv0.cdc`

**Description:**
`setInsuranceRate()` and `setStabilityFeeRate()` update the rate immediately without first collecting fees under the old rate or resetting collection timestamps. The next collection will compound the new rate over the entire elapsed period since the last collection, retroactively over- or under-charging reserves. Both setters also fail to call `updateInterestRates()`, leaving `currentCreditRate` stale.

**QS Recommendation:**
Force fee collection and an interest rate update before applying the new rate so that all previously elapsed time is settled at the old rate.

---

**Current code status (FlowALPv0.cdc):** ⚠️ **Still present.**
`setInsuranceRate()` (line 1658) and `setStabilityFeeRate()` (line 1770) both call only `tsRef.setInsuranceRate(insuranceRate)` / `tsRef.setStabilityFeeRate(stabilityFeeRate)`. Neither triggers `_collectInsurance()`, `_collectStability()`, or `updateInterestRates()` before writing the new value.

### Claude

**Explanation:** When governance changes a fee rate, the new rate should only apply going forward. But the protocol skips collecting what was already owed under the old rate before making the switch. The next time collection runs, it uses the new rate and applies it over all the elapsed time — including time that should have been billed at the old rate. If governance raises the rate, users get overcharged for the past; if it lowers the rate, the protocol undercharges.

**Recommendation:** Fix this. Governance rate changes should always settle the accrued fees under the current rate before switching. The pattern is straightforward: call the existing `_collectInsurance()` / `_collectStability()` helpers (which already reset timestamps) and then `updateInterestRates()` before updating the rate variable. This is a one-time, low-risk addition to two setter functions.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

## FLO-3 – Automatic Rebalancing Drains `topUpSource` Even if Position Remains Liquidatable

**Severity:** High | **File:** `FlowALPv0.cdc`

**Description:**
`_rebalancePositionNoLock()` withdraws from the user's `topUpSource` and deposits into the position without first verifying that the withdrawn amount is sufficient to bring health ≥ 1.0. If the source is underfunded, the protocol traps backup tokens in a doomed position where they will be seized by liquidators.

**QS Recommendation:**
Pre-flight check using `minimumAvailable()` to ensure the source can fully restore health to ≥ 1.0. Skip the withdrawal entirely if it cannot save the position.

---

**Current code status (FlowALPv0.cdc):** ⚠️ **Still present.**
In `_rebalancePositionNoLock()`, the code calls `topUpSource.withdrawAvailable(maxAmount: idealDeposit)` and immediately passes the result to `_depositEffectsOnly()` without checking whether the vault balance equals `idealDeposit`. `minimumAvailable()` is used in `availableBalance()` view function (line 331) but not in the rebalance path.

### Claude

**Explanation:** Users can configure a backup funding source (topUpSource) to automatically top up their position when it gets close to liquidation. But if that backup source doesn't have enough funds to fully rescue the position, the protocol takes whatever it can and dumps it into a position that will still be liquidated anyway. The user loses their backup funds to the liquidator — the exact outcome they were trying to avoid.

**Recommendation:** Fix this. The attack is straightforward and the user-harm is severe – they lose their backup funds to a liquidator they were trying to avoid. The fix is a single `if pulledVault.balance < fundsRequiredForTargetHealth(...)` check before depositing. Consider returning the pulled vault to the source if the check fails (or destroy it if the source does not accept returns), and emitting an event so off-chain tooling can surface the situation.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

## FLO-4 – `createPaidRebalancer` Is Permissionless, Anyone Can Drain Admin's FLOW

**Severity:** High | **File:** `FlowALPRebalancerPaidv1.cdc`

**Description:**
`createPaidRebalancer()` is `access(all)`. Any holder of a valid `ERebalance` capability can call it repeatedly, each call scheduling an immediate run funded from the admin's `txFunder`. No per-position deduplication or rate limiting exists.

**QS Recommendation:**
Restrict to admin-only, or add per-position deduplication tracking which positions already have a paid rebalancer and reject duplicates.

---

**Current code status (FlowALPRebalancerPaidv1.cdc):** ⚠️ **Still present.**
`createPaidRebalancer()` remains `access(all)` with no deduplication check.

### Claude

**Explanation:** The protocol offers a "paid rebalancer" where the admin covers the transaction fees on behalf of users. But anyone with a position capability can call `createPaidRebalancer()` as many times as they want, each time scheduling a fee-charged run at the admin's expense. Nothing stops a single user from creating thousands of paid rebalancers and draining the admin's FLOW balance.

**Recommendation:** Fix this. The simplest safe fix is to require an admin `EGovernance` capability to call `createPaidRebalancer()`. If the intent is that participants can set up their own paid rebalancer without admin involvement, track active rebalancer UUIDs per position in a pool-level set and `pre` that the position has no existing entry. The deduplication set should be updated on both creation and deletion (see FLO-27 for the deletion side).

#### **Action:** `[ ] No Action  [x] Code Changes  [x] Documentation`
- **Refactor:** Replace `uuid` with `positionID` in `createPaidRebalancer`.
- **Validation:** Add tests/docs confirming `createPaidRebalancer` panics on existing positions.
- **Security:** Document permissionless design.

#### **DRI:** holyfuchs

#### **Notes:**
- **Deduplication:** A check is added where `StoreRebalancer` will fail if multiple paid rebalancers are initiated for the same position.
- **Security:** The function is intentionally permissionless; however, a mandatory minimum deposit prevents malicious actors from spamming the state with high-volume, low-balance positions.

---

# MEDIUM SEVERITY

---

## FLO-5 – Inconsistent Flag Behavior: `pullFromTopUpSource` vs `pushToDrawDownSink`

**Severity:** Medium | **File:** `FlowALPv0.cdc`

**Description:**
`depositAndPush()` with `pushToDrawDownSink=true` always rebalances to `targetHealth`. `withdrawAndPull()` with `pullFromTopUpSource=true` only triggers a top-up when health drops below `minHealth`, ignoring the `minHealth < health < targetHealth` band. Users who expect symmetric behaviour (the flag keeps them at `targetHealth`) will be surprised.

**QS Recommendation:**
Update `withdrawAndPull()` to trigger a rebalance whenever health falls below `targetHealth` when `pullFromTopUpSource=true`.

---

**Current code status (FlowALPv0.cdc):** ⚠️ **Still present.**
`withdrawAndPull()` line 1459 checks for a `topUpSource` but the top-up only fires on a `minHealth` breach.

### Claude

**Explanation:** There are two operations with "auto-balance" flags: deposit-with-push and withdraw-with-pull. When you deposit with the sink flag on, the protocol rebalances you back to your target health. When you withdraw with the pull flag on, the protocol only reacts if your health falls below the absolute minimum — it ignores the target band entirely. Users expect both flags to behave the same way (keep me at my target), but they don't.

**Recommendation:** Fix this, but with care. The asymmetry is confusing and likely to cause user support issues. However, note the interaction with FLO-14 (rate-limiting throttles top-ups) and FLO-6 (queued deposits leave the position below `minHealth`). All three should be addressed together. If rate-limiting (FLO-14) is not fixed first, always pulling to `targetHealth` could still leave the position in an unexpected state.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

## FLO-6 – `withdrawAndPull()` Can Leave Position Below `minHealth` Due to Rate Limiting

**Severity:** Medium | **File:** `FlowALPv0.cdc`

**Description:**
When the required top-up exceeds the deposit rate limit, excess funds are queued instead of immediately credited. The final assertion only checks `health ≥ 1.0` (not `minHealth`), so the function succeeds while the position is left in a dangerously undercollateralised state.

**QS Recommendation:**
Bypass rate limiting for internal top-up operations, OR tighten the post-withdrawal assertion to `health ≥ minHealth`.

---

**Current code status (FlowALPv0.cdc):** ⚠️ **Still present.**
Final assertion at approximately line 1548 checks `postHealth >= 1.0`, not `>= position.getMinHealth()`.

### Claude

**Explanation:** When you withdraw funds and the protocol tries to top you up from your backup source, it may not be able to deposit everything at once due to rate limits — some funds go into a queue for later. The protocol then checks "is the position still solvent?" but its bar for "solvent" is only `health > 1.0` (not liquidatable), not the user's configured `minHealth`. So the withdrawal succeeds even though the position is now in the danger zone the user specifically configured to avoid.

**Recommendation:** The tighter assertion (`>= minHealth`) is the correct fix and has no downside – it simply rejects a withdraw that would otherwise silently leave the position vulnerable. The bypass of rate limits for top-ups (also requested in FLO-14) is a stronger fix. Both can be done independently. Start with the assertion tightening as it is lower risk.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

## FLO-7 – Minimum Position Balance Invariant Bypassed via Deposits

**Severity:** Medium | **File:** `FlowALPv0.cdc`

**Description:**
`_depositEffectsOnly()` does not enforce `minimumTokenBalancePerPosition`, allowing partial debt repayments to leave dust balances. View functions `maxWithdraw()` and `computeAvailableWithdrawal()` also ignore the threshold, causing frontends to suggest amounts that will revert on execution.

**QS Recommendation:**
Enforce the invariant at the end of `_depositEffectsOnly()`. Align view functions to account for it.

---

**Current code status (FlowALPv0.cdc):** ⚠️ **Still present.**
`_depositEffectsOnly()` has no `minimumTokenBalancePerPosition` check. Withdrawal path enforces it (post-condition in `withdrawAndPull()`), but not deposits.

### Claude

**Explanation:** The protocol has a rule: no position should hold a tiny "dust" balance in a token (it's operationally messy). This rule is enforced when you withdraw, but not when you deposit. So a partial repayment that leaves a tiny debt balance slips through. Worse, the "how much can I withdraw?" view functions don't account for this rule either — so the UI will suggest amounts that actually revert when submitted.

**Recommendation:** Fix this. Dust debit balances pollute pool state, break accounting edge cases, and the view-function mismatch causes a frustrating UX where the suggested maximum withdrawal immediately reverts. The enforcement in `_depositEffectsOnly()` is low-risk (a single post-condition). For the view functions, the logic is: "return `max(0, maxRawWithdrawal - minimumBalanceAdjustment)`".

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

## FLO-8 – `setInterestCurve()` Updates Rates Immediately, No Timelock

**Severity:** Medium | **File:** `FlowALPv0.cdc`

**Description:**
Governance can instantly change the interest rate model (e.g. fixed → kinked curve). A user's transaction submitted under a low-rate environment can execute under a drastically different rate if a governance transaction is ordered first in the same block.

**QS Recommendation:**
Implement a timelock for interest curve changes, or require debt-creating operations to include a slippage parameter.

---

**Current code status (FlowALPv0.cdc):** ⚠️ **Still present.** No timelock mechanism exists.

### Claude

**Explanation:** Governance can change the interest rate model at any time with no delay. A user who submits a borrow transaction at 5% APY can end up executing at 25% APY if a governance transaction lands in the same block right before theirs. There's no way for a user to protect themselves against this without a slippage guard or advance notice.

**Recommendation:** A full on-chain timelock is complex to implement. A pragmatic approach for v0:
1. **Short term (documentation):** Document in the protocol README and user-facing docs that interest curves can change without notice. This may be acceptable for a beta protocol with a trusted governance multisig.
2. **Medium term (code):** Add a slippage parameter `maxBorrowRate: UFix64` to `withdraw()` and assert `currentDebitRate <= maxBorrowRate`. This is a single `pre` condition per function.
3. **Long term:** Consider a 48-hour timelock for production.
For v0, lean toward option 1+2 as a combined approach.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

## FLO-9 – `regenerateDepositCapacity()` Permanently Inflates `depositCapacityCap`

**Severity:** Medium | **File:** `FlowALPModels.cdc`

**Description:**
Every time `regenerateDepositCapacity()` fires (every hour), it adds `depositRate * multiplier` to `depositCapacityCap` (the static ceiling) rather than to `depositCapacity` (the current fill level). The cap grows unboundedly, eventually disabling rate limiting entirely.

**QS Recommendation:**
Use a static `depositCapacityCap` as the bucket size and only refill `depositCapacity` up to that cap.

---

**Current code status (FlowALPModels.cdc):** ⚠️ **Still present and confirmed.**
Lines 1466–1469:
```cadence
let newDepositCapacityCap = self.depositRate * multiplier + self.depositCapacityCap
self.depositCapacityCap = newDepositCapacityCap          // cap grows each hour
self.setDepositCapacity(newDepositCapacityCap)           // fill = cap (also inflated)
```
The cap accumulates `depositRate * elapsed_hours` indefinitely.

### Claude

**Explanation:** Think of deposit rate limiting like a bucket: it has a fixed maximum size (the cap) and refills at a set rate each hour. The bug here is that every hour, not only does the bucket refill — the maximum size of the bucket also grows permanently. After a few days the bucket is enormous, and after a few weeks the rate limit is essentially infinite and meaningless. One actor could eventually deposit unlimited amounts in a single block.

**Recommendation:** Fix this immediately. The bug completely defeats the deposit rate-limiting mechanism over time and can allow a single actor to monopolise pool liquidity. The correct implementation is:
```cadence
// DON'T modify depositCapacityCap – it's the static ceiling
let newCapacity = self.depositCapacity + self.depositRate * multiplier
self.setDepositCapacity(min(newCapacity, self.depositCapacityCap))
```
Note: the `oldCap` variable on line 1466 is computed but never used – a sign this was partially worked on. Also note the interaction with FLO-30: `depositLimit()` currently uses `self.depositCapacity * self.depositLimitFraction` (dynamic). After this fix, both FLO-9 and FLO-30 should be addressed together.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

## FLO-10 – `asyncUpdate` Single Position Revert Blocks Entire Batch

**Severity:** Medium | **File:** `FlowALPv0.cdc`

**Description:**
`asyncUpdate()` calls `asyncUpdatePosition()` for each queued position in a single transaction. External calls to user-supplied `topUpSource` or `drawDownSink` can panic, reverting the entire batch. A single malicious or buggy source/sink permanently blocks all other queued positions. A TODO comment in the code explicitly acknowledges this.

**QS Recommendation:**
Wrap each `asyncUpdatePosition()` call in try/catch, or schedule each position update as a separate callback.

---

**Current code status (FlowALPv0.cdc):** ⚠️ **Still present.** The TODO comment remains and no error isolation has been added.

### Claude

**Explanation:** The protocol processes a queue of positions that need updating in a single transaction — one after another in a loop. Each position can make external calls to user-configured sources and sinks. If any one of those external calls panics (due to a bug or a deliberately malicious implementation), the entire transaction reverts, and none of the other positions get updated. One bad actor can permanently block everyone else's position updates.

**Recommendation:** Fix this before going to production. Cadence does not have `try/catch`, so the correct approach is the one noted in the TODO: schedule each position update as an independent scheduled transaction callback. This is architecturally the right model and removes the griefing vector entirely. As a short-term mitigation, consider adding a `failedUpdateCount` per position and after N consecutive failures, automatically dequeueing the position and emitting an alert event. This won't protect other positions in the same batch but limits long-term queue poisoning.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

## FLO-11 – Inconsistent MOET Accounting Leads to Supply Inflation

**Severity:** Medium | **File:** `FlowALPv0.cdc`

**Description:**
Automated rebalancing mints new MOET tokens and sends them to the user's sink. But when MOET debt is repaid via `depositToPosition()`, the tokens are stored in the reserve vault rather than burned. Manual borrows pull from the reserve (which may be empty). Over time, this produces unbacked MOET supply inflation and "liquidity mirages" where reserves appear to hold MOET that is not collateral-backed.

**QS Recommendation:**
Standardise MOET as a pure CDP asset: mint on borrow, burn on repayment.

---

**Current code status (FlowALPv0.cdc):** ⚠️ **Still present.** Repayments in `_doLiquidation()` (and deposit path) deposit into `reserveRef` without burning. No `burn()` call exists in the repayment flow.

### Claude

**Explanation:** MOET is a protocol-issued token that should follow a simple rule: mint when borrowed, burn when repaid. But when MOET debt gets repaid, those tokens go into the reserve vault instead of being burned. Meanwhile, new MOET is still minted fresh whenever the rebalancer needs to push excess collateral to a sink. Over time, the total MOET supply grows beyond what's actually backed by collateral — the reserve appears to hold real MOET but it's just an artifact of incomplete accounting.

**Recommendation:** This is a correctness issue that will compound over time if the protocol stays in production. The fix (burn on MOET repayment) is conceptually simple but requires care: only MOET deposits that reduce a *debit* balance should trigger a burn; a MOET deposit into a position that is in *credit* is a collateral deposit, not a repayment, and must not burn. The accounting logic to distinguish these cases already exists in `_depositEffectsOnly()`. This change should be accompanied by a test that verifies MOET `totalSupply() == sum(all MOET debit balances)` as an invariant.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

## FLO-12 – Fee Calculation Diverges From Rate Allocation Formula

**Severity:** Medium | **File:** `FlowALPv0.cdc`

**Description:**
`updateInterestRates()` deducts fees as an instantaneous rate from `currentCreditRate`. `collectInsurance()` / `collectStability()` compute fees using compounding (`powUFix128(debitRate, timeElapsed) - 1`). These produce different totals because `totalDebitBalance` and `currentDebitRate` change between collections, causing accounting drift over time.

**QS Recommendation:**
Use the same formula in both the allocation and collection paths.

---

**Current code status (FlowALPv0.cdc):** ⚠️ **Partially improved but divergence remains.**
Both paths now use `debitIncome * rate` as the structure. However, `updateInterestRates()` uses `totalDebitBalance * currentDebitRate` (instantaneous) while `_collectInsurance()` uses `totalDebitBalance * (powUFix128(currentDebitRate, timeElapsed) - 1)` (compound over elapsed time). The structural mismatch persists.

### Claude

**Explanation:** Protocol fees are calculated in two separate places using slightly different math. The rate allocation path uses a simple instantaneous snapshot (balance × rate right now). The fee collection path compounds the rate over elapsed time (more accurate). Because loans are taken out and repaid in between collections, the two calculations produce different totals — the protocol ends up collecting a slightly different amount than what was allocated to lenders. This is a drift in accounting accuracy, not a fund-loss bug.

**Recommendation:** This is a design-level decision. The compounding formula in collection is more accurate (it accounts for interest on interest over the elapsed period). The credit-rate allocation path should match. Consider using the same compounding formula in `updateInterestRates()` or, pragmatically, document the intentional approximation and bound the drift. If collection frequency is high (seconds to minutes), the linear/compound difference is negligible for reasonable rates. If the protocol is dormant for hours, drift can be material. Add a comment explaining the acceptable error margin.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

## FLO-13 – Fee Collection Drains Reserves Below Seize Amount, Causing Liquidation Revert

**Severity:** Medium | **File:** `FlowALPv0.cdc`

**Description:**
In the audited version, `manualLiquidation()` triggered fee collection via `updateForTimeChange()` before the seize withdrawal. If fee collection drained reserves below `seizeAmount`, the liquidation would revert. This is especially dangerous after long idle periods.

**QS Recommendation:**
Ensure fee collection cannot drain reserves below a pending liquidation's seize amount.

---

**Current code status (FlowALPv0.cdc):** ✅ **Appears addressed.**
`manualLiquidation()` now directly calls `_doLiquidation()` without invoking `updateForTimeChange()` first. Fee collection is decoupled from the liquidation path. However, this should be confirmed by reviewing whether any path into `manualLiquidation()` still touches fee collection.

### Claude

**Explanation:** In an older version of the code, triggering a liquidation would first run protocol fee collection as a side effect. If the pool had been idle for a long time and fees had accumulated, that fee collection could drain the reserve so much that there wasn't enough left to actually pay out the collateral being seized — causing the liquidation itself to fail. This appears to have been fixed by decoupling fee collection from the liquidation path.

**Recommendation:** Verify this explicitly in code review. If `updateForTimeChange()` is truly not called in the liquidation hot path, this finding is resolved. Add a comment to `manualLiquidation()` documenting the intentional absence of fee collection ("fee collection is intentionally deferred to avoid blocking liquidations"). Also confirm that the segregation does not create a new issue where fees accumulate excessively without ever being collected.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

## FLO-14 – Deposit Rate Limiting Throttles Critical Rebalance Top-Ups

**Severity:** Medium | **File:** `FlowALPv0.cdc`

**Description:**
In `_rebalancePositionNoLock()`, the top-up funds from `topUpSource` are routed through `_depositEffectsOnly()` which enforces standard user-facing deposit rate limits. If only a fraction of the required top-up is immediately deposited (the rest queued), the position remains undercollateralised and may be liquidated before the queue drains.

**QS Recommendation:**
Bypass rate limits for internal rebalance deposits.

---

**Current code status (FlowALPv0.cdc):** ⚠️ **Still present.** Rate limits are enforced in `_depositEffectsOnly()` with no bypass flag.

### Claude

**Explanation:** Deposit rate limiting exists to prevent any single user from monopolising the pool by depositing too much at once. But this same rate limit also applies when the protocol automatically tops up a position that's approaching liquidation. If the required rescue deposit is larger than the current rate limit allows, only part of it goes through immediately — the rest is queued. The position is still dangerously undercollateralised and could be liquidated before the queue processes. The same safety guard designed to protect the pool ends up preventing the pool from protecting users.

**Recommendation:** Fix this. Rebalancing is a protocol-safety-critical operation and should not be subject to the same anti-monopoly rate limits designed for user deposits. Add an `internal: Bool` parameter (or a separate `_depositEffectsOnlyInternal()` function) that bypasses `depositLimit()` checking and does not consume `depositCapacity`. This is a contained change. Note: fixing FLO-3 (pre-flight check on topUpSource) first is a prerequisite – once we know the source has enough funds, we need to ensure all of them land immediately.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

## FLO-15 – Same-Token Shortcut Incorrectly Linearises Health Computation

**Severity:** Medium | **File:** `FlowALPv0.cdc`

**Description:**
In `fundsAvailableAboveTargetHealthAfterDepositing()`, when `depositType == withdrawType`, a shortcut returns `fundsAvailable + depositAmount`. This is wrong when the position has a debit balance in that token: debt repayment reduces debt via `borrowFactor` while collateral addition uses `collateralFactor`. The shortcut ignores this scaling difference.

**QS Recommendation:**
Remove the shortcut and use the full computation path for all cases.

---

**Current code status (FlowALPv0.cdc):** ⚠️ **Still present.** The same-token shortcut remains at approximately line 859.

### Claude

**Explanation:** The function "how much can I withdraw if I also deposit X of the same token?" has a shortcut: it just adds the deposit amount to the normal withdrawal amount. This works fine if the position has no debt in that token. But if there's an existing debt, depositing that token works differently — it reduces debt (scaled by the borrow factor) rather than just adding collateral (scaled by the collateral factor). These two factors are different, so depositing and then withdrawing the same amount is not a neutral operation. The shortcut overcounts what's actually available to withdraw.

**Recommendation:** Fix this. The shortcut produces incorrect "available to withdraw" amounts for any position with a same-token debit balance and can cause UX issues (frontend shows wrong borrowing capacity) and potential protocol-level issues if downstream logic depends on the view function. The non-shortcut path (`computeAdjustedBalancesAfterDeposit`) already handles this correctly – simply remove the shortcut branch and let all cases fall through to the full computation. Add a test for the specific case: position has debit in token A, deposit token A → correct available withdrawal computed.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

## FLO-16 – Potential Underflow Subtracting Token's Effective Collateral Contribution

**Severity:** Medium | **File:** `FlowALPv0.cdc`

**Description:**
In `computeAdjustedBalancesAfterWithdrawal()`, when a withdrawal flips a credit balance to debt, the code subtracts the token's contribution from `effectiveCollateral`. Due to intermediate UFix128 rounding differences between the original summation path and the local recomputation, the subtraction can underflow (UFix128 is unsigned), panicking and blocking the withdrawal.

**QS Recommendation:**
Floor the subtraction at zero.

---

**Current code status (FlowALPv0.cdc):** ⚠️ **Still present.** No floor-at-zero guard exists in `computeAdjustedBalancesAfterWithdrawal()`.

### Claude

**Explanation:** When you withdraw enough of a token to flip from lending (credit) to borrowing (debit), the protocol recalculates your health score and needs to subtract that token's collateral contribution. Due to tiny rounding differences in how the number was originally added vs. how it's being subtracted back, the amount to subtract can be infinitesimally larger than what's available. Since the protocol uses unsigned integers, this causes an underflow crash — the withdrawal is completely blocked even though the actual rounding error is economically meaningless (less than a fraction of a cent).

**Recommendation:** Fix this immediately – it is a one-line change with zero functional downside. A rounding error of 1 UFix128 unit is economically irrelevant; flooring at zero is safe. This is blocking a user operation (withdrawals that flip credit to debit), which is a core protocol feature. Add a test that exercises the credit→debit flip path to catch any future regression.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

## FLO-17 – Refund Destination Changes After Recurring Config Updates

**Severity:** Medium | **File:** `FlowALPRebalancerv1.cdc`

**Description:**
`setRecurringConfig()` overwrites `self.recurringConfig` with the new config, then calls `cancelAllScheduledTransactions()`. The cancellation refunds fees using `self.recurringConfig.getTxFunder()` — which is now the *new* funder. Fees originally paid by the old funder are incorrectly refunded to the new funder.

**QS Recommendation:**
Cancel scheduled transactions using the old funder *before* replacing the config.

---

**Current code status (FlowALPRebalancerv1.cdc):** ⚠️ **Still present.**
Lines 285–292: `self.recurringConfig = config` is assigned on line 286 before `cancelAllScheduledTransactions()` is called on line 287.

### Claude

**Explanation:** When you update your rebalancer's schedule configuration, any pre-paid fees for already-scheduled transactions need to be cancelled and refunded. But the code swaps in the new config first, then does the cancellations. By the time it refunds the fees, it sends them to the new fee-payer — not the original one who paid. If you're switching from one fee-paying account to another, the old account's money ends up in the new account's wallet.

**Recommendation:** Fix this. The fix is straightforward: save the old config before overwriting, cancel using the saved reference, then assign the new config. However, also read FLO-28 together with this fix, as the two interact: the FLO-17 fix can introduce the deadlock described in FLO-28. Both must be addressed in the same PR.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

# LOW SEVERITY

---

## FLO-18 – `perSecondInterestRate()` Uses Linear Instead of Logarithmic Decomposition

**Severity:** Low | **File:** `FlowALPv0.cdc`

**Description:**
The per-second rate is computed as `annualRate / 31536000`. Interest is then applied using `rate^timeElapsed` (exponential). This means the effective APY exceeds the stated annual rate. The divergence grows with the interest rate.

**QS Recommendation:**
Use `r_sec = ln(1 + r_annual) / 31536000` (requires off-chain pre-computation or Taylor series approximation).

---

### Claude

**Explanation:** To go from an annual rate (e.g. 10% per year) to a per-second rate, the code divides by the number of seconds in a year. But interest is then applied by compounding that per-second rate continuously. These two operations aren't inverses of each other — the compounding effectively "over-applies" the rate, and the actual annual yield ends up slightly higher than advertised. At 10% APY the overshoot is about 0.5%; at 30% it's about 4%. The correct approach is to use a logarithm when converting from annual to per-second, but Cadence doesn't have `ln()` natively.

**Recommendation:** The economic impact of this bug at typical DeFi rates (5–30% APY) is small but real. At 10% APY, a linear decomposition overstates the effective rate by ~0.5%; at 30%, by ~4%. For v0 with low TVL this is acceptable risk. The recommended approach is to compute the correct per-second rate off-chain before calling `setInterestCurve()`. No on-chain change needed – add a helper script/tooling note and document the expectation that callers must pass the logarithmically-derived rate. Mark as a tooling/documentation fix.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

## FLO-19 – `dexOraclePriceDeviationInRange()` Enforces Asymmetric Price Bounds

**Severity:** Low | **File:** `FlowALPv0.cdc`

**Description:**
The deviation is computed as `|dexPrice - oraclePrice| / min(dexPrice, oraclePrice)`. When the DEX price is below the oracle, the denominator is smaller, making the deviation appear larger and the check more likely to reject. When the DEX price is above the oracle, the oracle is the denominator, making the check more lenient. The resulting acceptable range is asymmetric.

**QS Recommendation:**
Always use the oracle price as the denominator.

---

### Claude

**Explanation:** When a liquidation uses a DEX swap, the protocol checks that the DEX price isn't too far from the oracle price. The deviation is calculated as the difference divided by whichever price is smaller. This means a DEX price that's 5% below oracle looks like a bigger deviation than a DEX price that's 5% above oracle. In practice, the check is stricter when DEX prices are low (favouring the liquidator) and more lenient when DEX prices are high. Using the oracle price as a fixed denominator would make the check symmetric.

**Recommendation:** Fix this. The code comment says this is "intentional" but the asymmetry favours higher DEX prices (i.e., the liquidator seizing more collateral cheaply). Using the oracle as the fixed denominator is the standard approach and removes the bias. It's a single-line change with no side-effects. The existing test suite should be updated to confirm the symmetric range.

**Action:** `[ ] No Action  [x] Code Changes  [ ] Documentation`
**DRI:** holyfuchs
**Notes:**
We use the DEX price as the denominator because it represents the actual execution price of the swap, making it our primary reference for realized value.
Measuring deviation relative to the DEX price ensures we are tracking the percentage of "lost" or "gained" value based on the tokens we are actually trading.

---

## FLO-20 – `createPosition()` Causes Storage Bloat via Redundant Capability Issuance

**Severity:** Low | **File:** `FlowALPv0.cdc`

**Description:**
Every `createPosition()` call issues a new `auth(EPosition) &Pool` storage capability, creating a new persistent Capability Controller in the contract account, even though all controllers point to the same storage path.

**QS Recommendation:**
Issue the capability once at pool creation, cache it, and copy it into each new position.

---

### Claude

**Explanation:** Every time a user creates a new position, the contract also creates and permanently stores a new capability object on-chain — even though all these capability objects are identical and point to the same thing. With thousands of users each creating positions, this results in thousands of redundant objects cluttering the contract account's storage unnecessarily. A single shared capability created once at pool setup would do the same job for all positions.

**Recommendation:** Fix before scaling. Each issued storage capability persists indefinitely in the Flow account state. At thousands of positions, this creates real on-chain bloat. The fix (cache once at `createPool()`) is clean and non-breaking. Cadence capability structs are value types and can be safely stored and copied.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

## FLO-21 – Mandatory `drawDownSink` in `createPosition()` Contradicts Optional Design

**Severity:** Low | **File:** `FlowALPv0.cdc`

**Description:**
`createPosition()` requires a non-optional `issuanceSink` parameter, but `setDrawDownSink()` and `provideSink()` treat it as optional. Users who don't need an issuance sink must supply one at creation anyway, creating unnecessary friction.

**QS Recommendation:**
Make the `issuanceSink` parameter optional in `createPosition()`.

---

### Claude

**Explanation:** The draw-down sink is intended to be optional — you can set it or leave it unset at any time after creation. But the position creation function requires you to provide one upfront. Users who don't want or need a draw-down sink are forced to supply a placeholder just to create a position, which is awkward and inconsistent with how the rest of the API treats it.

**Recommendation:** Fix this as a UX improvement. Making the parameter `{DeFiActions.Sink}?` with a `nil` default is a backwards-compatible change (callers can still pass a non-nil sink). The underlying storage setter already handles `nil` cleanly. Low-risk, low-effort improvement.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

## FLO-22 – `maxWithdraw()` View Function Incorrectly Caps Credit Position Withdrawals

**Severity:** Low | **File:** `FlowALPv0.cdc`

**Description:**
`maxWithdraw()` caps the return value at `trueBalance` for credit positions, ignoring the protocol's ability to flip the balance into debt (i.e., borrow beyond zero). This causes frontends to show dramatically lower available-to-borrow figures than what the protocol actually supports.

**QS Recommendation:**
Return `trueBalance + allowable debt capacity` for credit positions.

---

### Claude

**Explanation:** The "how much can I withdraw?" view function stops at zero — it tells you how much of your deposited balance you can take out, but it doesn't tell you that you can keep withdrawing beyond zero (i.e., borrow). A user who has deposited 1000 USDC and wants to borrow against their collateral would see "max: 1000 USDC" even if the protocol would allow them to borrow 500 more. Frontends relying on this function would show the wrong borrowing limit.

**Recommendation:** Fix this. The discrepancy between the view function and the actual execution is a UX bug that will confuse users and require manual workarounds from frontend developers. The correct formula is already implemented in `computeAvailableWithdrawal()` – align `maxWithdraw()` with that implementation. This is a view-only change with no risk to protocol solvency.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

## FLO-23 – Manual Liquidations Bypass Configured Top-up Sources

**Severity:** Low | **File:** `FlowALPv0.cdc`

**Description:**
`manualLiquidation()` does not attempt to use the position's `topUpSource` before executing. Since automated rebalancing is asynchronous, a liquidator can front-run the rebalance bot and liquidate a position that could have been saved using the user's configured backup funds.

**QS Recommendation:**
Attempt `_rebalancePositionNoLock(force: true)` inside `manualLiquidation()` before checking health.

---

### Claude

**Explanation:** Users can configure a backup source to automatically rescue their position before it gets liquidated. But a fast liquidator can submit a liquidation transaction before the rebalance bot gets a chance to run. The liquidation path never checks whether the user's backup source could have saved the position — it just seizes the collateral. The user set up a safety net that the protocol ignores at the exact moment they need it.

**Recommendation:** Consider fixing, but note the complexity: calling `_rebalancePositionNoLock()` inside `manualLiquidation()` means external calls to `topUpSource` happen during the liquidation flow, which increases reentrancy risk (see FLO-29). Also consider the griefing angle: a malicious `topUpSource` could cause the liquidation to revert indefinitely. A safer design is to attempt rebalance from a separate pre-liquidation transaction (off-chain liquidation bot responsibility) rather than embedding it in `manualLiquidation()`. Document this expectation clearly instead.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

## FLO-24 – Updating Health Bounds Doesn't Queue Position for Rebalancing

**Severity:** Low | **File:** `FlowALPv0.cdc`

**Description:**
`setMinHealth()` and `setMaxHealth()` update the bounds but don't call `_queuePositionForUpdateIfNecessary()`. If the new bounds instantly render the position rebalance-eligible, the async loop will miss it until a future state-changing operation triggers the queue check.

**QS Recommendation:**
Call `_queuePositionForUpdateIfNecessary()` from within the health bound setters.

---

### Claude

**Explanation:** When you change your position's minimum or maximum health thresholds, the protocol updates the numbers but doesn't check whether your position is now out of bounds under the new settings. For example, if you lower your `maxHealth` to trigger a draw-down of excess collateral, nothing happens immediately — the rebalance only fires the next time some other operation happens to queue your position. Users will be confused why their health bounds change had no apparent effect.

**Recommendation:** Fix this as a low-effort improvement. Users who lower `maxHealth` to extract excess collateral will be confused when nothing happens. The `_queuePositionForUpdateIfNecessary()` function already exists and does exactly this check – add a call to it at the end of `setMinHealth()` and `setMaxHealth()`. One-line fix per function.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

## FLO-25 – DEX Price Susceptible to Sandwich Attacks in Liquidation

**Severity:** Low | **File:** `FlowALPv0.cdc`

**Description:**
`manualLiquidation()` fetches a DEX spot quote and compares it in the same transaction. An attacker can sandwich: manipulate the DEX to worsen its quote, execute the liquidation (whose offer now looks "better than DEX"), then reverse the manipulation.

**QS Recommendation:**
Use TWAP or oracle price as the benchmark instead of spot quote.

---

### Claude

**Explanation:** When a liquidation uses a DEX to swap the seized collateral, the protocol checks that the DEX price is close to the oracle price as a fairness guard. But an attacker can manipulate the DEX spot price right before the liquidation (making it look worse), execute the liquidation (which now appears to beat the "bad" DEX price), then immediately reverse the manipulation for a profit. The DEX spot price used as a reference is itself the attack surface.

**Recommendation:** For v0, the oracle-price check that already exists (`dexOraclePriceDeviationInRange`) provides a meaningful bound. If the oracle price is reliable, it largely mitigates the sandwich risk. The DEX comparison is belt-and-suspenders. Evaluate whether the DEX comparison is even necessary – if the oracle check is the primary guard, the DEX quote may be redundant. Longer term, switching to a TWAP oracle is best practice. Document the current mitigations.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

## FLO-26 – `seizeType` and `debtType` Can Be the Same Token in Liquidation

**Severity:** Low | **File:** `FlowALPv0.cdc`

**Description:**
`manualLiquidation()` has no `pre` condition requiring `seizeType != debtType`. When they match, `recordDeposit()` and `recordWithdrawal()` operate on the same `InternalBalance` sequentially, and the net accounting effect may differ from the health pre-computation.

**QS Recommendation:**
Add `pre { seizeType != debtType }`.

---

### Claude

**Explanation:** In a liquidation, the liquidator repays a debt (in one token) and receives seized collateral (in another token). But nothing prevents someone from submitting a liquidation where both sides are the same token — repaying FLOW debt and seizing FLOW collateral. This is economically pointless, but the accounting operations happen sequentially on the same balance, which can produce results that don't match the health calculation that was supposed to justify the liquidation.

**Recommendation:** Fix this. It's a one-line `pre` condition. Same-token liquidation is economically nonsensical and the accounting edge case is non-trivial to reason about. Rejecting it cleanly is safer than allowing undefined behaviour.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

## FLO-27 – Stale Supervisor UUID Bricks Recovery Calls

**Severity:** Low | **File:** `FlowALPRebalancerPaidv1.cdc`, `FlowALPSupervisorv1.cdc`

**Description:**
`fixReschedule(uuid:)` force-unwraps `borrowRebalancer(uuid)!`. If a paid rebalancer is deleted without removing its UUID from the Supervisor's `paidRebalancers` set, the next Supervisor tick panics on the stale UUID, blocking rescheduling for *all* other paid rebalancers in that run.

**QS Recommendation:**
Make `fixReschedule` non-panicking on missing UUID (use optional unwrap + early return). Isolate per-UUID failures in the Supervisor loop.

---

### Claude

**Explanation:** The Supervisor keeps a list of all paid rebalancer UUIDs and periodically calls each one to reschedule. If a paid rebalancer resource gets deleted but its UUID isn't removed from the Supervisor's list, the next time the Supervisor runs it tries to look up that UUID, gets nil, and panics. This one stale entry crashes the entire Supervisor loop — every other paid rebalancer in the system stops getting rescheduled until someone manually fixes the list.

**Recommendation:** Fix this. The force-unwrap is clearly wrong – missing UUID should be a soft warning, not a panic. Change `borrowRebalancer(uuid)!` to `borrowRebalancer(uuid) ?? return` (guard pattern). Also see FLO-4: part of the fix for FLO-4 is tracking active rebalancer UUIDs – that same registry should be the authoritative source for the Supervisor set, ensuring they stay in sync.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

## FLO-28 – Safe Refund Ordering Can Brick Config Rotation

**Severity:** Low | **File:** `FlowALPRebalancerv1.cdc`

**Description:**
If FLO-17 is fixed (cancel before overwriting config), a new deadlock emerges: if the old `txFunder` has reached its `depositCapacity`, the refund deposit panics, making it impossible to call `setRecurringConfig()` and install a new, healthy funder.

**QS Recommendation:**
Make cancellation non-blocking on refund failure: store the remainder as a pending refund and emit an event instead of panicking.

---

### Claude

**Explanation:** This is a follow-on to FLO-17. Once you fix that bug (refund to the old fee-payer before swapping config), a new problem surfaces: what if the old fee-payer's account is at its deposit capacity limit and can't accept the refund? The code panics, which means you can never successfully call `setRecurringConfig()` — you're permanently stuck with the old, broken config and can't swap in a new healthy fee-payer to fix it. The very fix you needed is now inaccessible.

**Recommendation:** FLO-17 and FLO-28 must be fixed together. The cleanest approach:
1. Save old config reference before overwriting.
2. On cancellation, if the refund can't be deposited into the old txFunder, store it in a `pendingRefunds: {UInt64: @{FungibleToken.Vault}}` map in the Rebalancer.
3. Provide a separate `claimPendingRefund()` function the old funder operator can call.
4. Emit an event so off-chain tooling is alerted.
This avoids the deadlock while preserving the correct-ownership invariant.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

## FLO-29 – Per-Position Reentrancy Lock Does Not Protect Shared Pool State

**Severity:** Low | **File:** `FlowALPv0.cdc`

**Description:**
The reentrancy guard (`_lockPosition` / `_unlockPosition`) is scoped to a single position ID. While position A is locked and making external calls (oracle, DEX swapper, sink, source), position B can freely read and write shared mutable pool state (reserves, `TokenState` balances, interest indices, deposit capacity).

**QS Recommendation:**
Consider a pool-level lock, locking affected `TokenState`/reserve vaults, or a pre/post snapshot validation approach.

---

### Claude

**Explanation:** The protocol has a reentrancy lock, but it only locks one position at a time. While position A is locked and making external calls to user-configured sources or sinks, another user can come in with position B and freely modify shared pool data like reserve balances, interest rates, and deposit capacity. In Cadence/Flow's single-threaded model this is harder to exploit than in EVM, but it's still a correctness gap — shared state can change mid-operation in ways the locked position didn't account for.

**Recommendation:** This is a genuine architectural concern but difficult to fix without major refactoring. Flow/Cadence's object-capability model and the absence of async concurrency reduce (but don't eliminate) the practical risk compared to EVM. A pragmatic approach for v0:
1. Document which external calls occur and what shared state they can affect.
2. Order operations to minimise the window (perform all external calls before state mutations where possible).
3. Add a global "pool-level operation in progress" boolean lock as a lightweight guard.
A full pool-level lock is the ideal solution but should be evaluated against performance impact.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

# INFORMATIONAL

---

## FLO-30 – `depositLimit()` Creates Transaction Order Dependency

**Severity:** Informational | **File:** `FlowALPv0.cdc`

**Description:**
`depositLimit()` = `depositCapacity * depositLimitFraction`. As the pool fills, `depositCapacity` shrinks and the per-deposit limit shrinks asymptotically, making full capacity exhaustion mathematically impossible and penalising users based on block ordering.

**QS Recommendation:**
Multiply `depositLimitFraction` by the static `depositCapacityCap` instead.

---

### Claude

**Explanation:** The maximum amount any single deposit can add to the pool is calculated as a fraction of the pool's remaining capacity. So as the pool fills up, the per-deposit limit shrinks. Near full capacity, the limit approaches zero — the last few users trying to fill the pool can only deposit a tiny sliver each time, and the pool can never actually reach 100% utilisation. Users who deposit earlier in the block get to deposit more than users who deposit later in the same block, which is an unfair ordering dependency.

**Recommendation:** Fix this together with FLO-9. Once FLO-9 is fixed (`depositCapacityCap` is static), `getUserDepositLimitCap()` (line 1355) already uses `depositCapacityCap` correctly. But `depositLimit()` (line 1381) still uses the dynamic `depositCapacity`. Make `depositLimit()` consistent with `getUserDepositLimitCap()`. This is a two-word change but has to be coordinated with FLO-9.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

## FLO-31 – Supported Tokens Cannot Be Removed

**Severity:** Informational | **File:** `FlowALPv0.cdc`

**Description:**
`addSupportedToken()` has no corresponding `removeSupportedToken()`. Once a token is added, governance can only "soft-disable" via extreme parameter values, which may confuse integrators.

**QS Recommendation:**
Add an explicit unsupport/pause mechanism, or document that parameter-tuning is the intended deprecation path.

---

### Claude

**Explanation:** The pool supports adding new tokens but has no formal way to remove them. If a token needs to be deprecated (e.g. it gets de-listed, exploited, or the protocol wants to migrate), governance has to resort to workarounds like setting the collateral factor and deposit cap to zero. This works functionally but doesn't clearly communicate "this token is disabled" to integrators, who may continue to query or interact with it expecting normal behaviour.

**Recommendation:** For v0, documentation is sufficient. A full `removeSupportedToken()` is complex (existing positions hold balances in the token; those would need to be migrated or unwound). The pragmatic governance path – setting `depositCapacityCap = 0` and `collateralFactor = 0` to effectively freeze a token – should be documented explicitly in the governance runbook. Add a `pauseToken(tokenType)` helper that applies these settings atomically with a clear event emission so integrators can observe the state.

**Action:** `[ ] No Action  [ ] Code Changes  [ ] Documentation`
**DRI:**
**Notes:**

---

# AUDITOR SUGGESTIONS (S1 – General Improvements)

**File:** `FlowALPv0.cdc` and transactions

| # | Issue | Action | DRI | Notes |
|---|-------|--------|-----|-------|
| S1.1 | Brittle `interestCurve` handling in `updateInterestRates()` – `else` branch missing type check | `[ ] No Action  [ ] Code Changes  [ ] Documentation` | | |
| S1.2 | Duplicate balance sheet construction across functions | `[ ] No Action  [ ] Code Changes  [ ] Documentation` | | |
| S1.3 | Use `view.trueBalance()` helper in `healthFactor()` | `[ ] No Action  [ ] Code Changes  [ ] Documentation` | | |
| S1.4 | `Pool.isLiquidatable()` panics for invalid `pid` | `[ ] No Action  [ ] Code Changes  [ ] Documentation` | | |
| S1.5 | `Pool.createPosition()` missing type checks for connectors | `[ ] No Action  [ ] Code Changes  [ ] Documentation` | | |
| S1.6 | Missing input validation in `Pool.setDexOracleDeviationBps()` | `[ ] No Action  [ ] Code Changes  [ ] Documentation` | | |
| S1.7 | Missing events for some setters (e.g. `setMinimumTokenBalancePerPosition()`) | `[ ] No Action  [ ] Code Changes  [ ] Documentation` | | |
| S1.8 | Allow custom `targetHealth` / `maxHealth` at position creation | `[ ] No Action  [ ] Code Changes  [ ] Documentation` | | |
| S1.9 | `liquidate_via_dex.cdc` and `liquidate_via_mock_dex.cdc` use deprecated functions | `[ ] No Action  [ ] Code Changes  [ ] Documentation` | | |
| S1.10 | `LiquidationExecutedViaDex` event is unused | `[ ] No Action  [ ] Code Changes  [ ] Documentation` | | |
| S1.11 | Validate `estimationMargin >= 1.0` in `FlowALPRebalancerPaidv1.cdc` | `[ ] No Action  [ ] Code Changes  [ ] Documentation` | | |

### Claude

**Recommendation on S1:**
- **S1.1** (type check in else branch): Fix – a missed type check can lead to silent wrong-path execution.
- **S1.4** (`isLiquidatable` panic on bad pid): Fix – use optional chaining, return `false` for unknown positions.
- **S1.5** (missing connector type checks): Fix – unchecked capabilities are a common Cadence footgun.
- **S1.6** (missing validation in `setDexOracleDeviationBps`): Fix – add a `pre` that the BPS value is within a reasonable range (e.g. 0–5000).
- **S1.7** (missing events): Fix – events are essential for off-chain monitoring.
- **S1.8** (custom health at creation): Nice-to-have improvement, low priority.
- **S1.9** (deprecated functions in transactions): Fix – stale transactions are confusing and may silently fail.
- **S1.10** (unused event): Remove or wire it up.
- **S1.11** (`estimationMargin >= 1.0`): Fix – a one-line `pre` condition that prevents a latent fee-underfunding bug.

---

## Priority Summary

| Priority | Findings | Rationale |
|----------|----------|-----------|
| **Fix before launch** | FLO-1, FLO-2, FLO-3, FLO-4, FLO-9, FLO-10, FLO-16 | Direct fund loss, broken invariants, or griefing vectors |
| **Fix soon** | FLO-5, FLO-6, FLO-7, FLO-11, FLO-14, FLO-15, FLO-17+FLO-28, FLO-26, FLO-27 | Protocol correctness issues that accumulate over time |
| **Document or minor fix** | FLO-8, FLO-12, FLO-13, FLO-18, FLO-19, FLO-20, FLO-21, FLO-22, FLO-23, FLO-24, FLO-25, FLO-29, FLO-30, FLO-31 | UX, efficiency, or edge cases with lower exploitability |
| **S1 items** | S1.1, S1.4–S1.7, S1.9–S1.11 | Low effort, good hygiene |
