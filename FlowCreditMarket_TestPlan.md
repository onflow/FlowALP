# FlowCreditMarket – High-Priority Test Plan

This document lists **workflow-centric** test cases that deliver maximum coverage for `FlowCreditMarket.cdc` and its satellite contracts while fitting comfortably into a single, review-friendly pull-request.  Each case follows the conventions captured in `CadenceTestingPatterns.md`.

Legend
* **LOC≈** – rough new lines of test-code (excluding transactions/scripts).  Keep total ≈ **300–400 LOC** per PR.
* **Fixtures** – helpers or artefacts reused across cases.
* **Key Assertions** – behavioural checks, not mere success codes.

---

## 1. Pool Creation Workflow
* **Filename**: `pool_creation_workflow_test.cdc`
* **LOC≈** 60
* **Flow**
  1. `setup()` deploys contracts.
  2. Service account calls `create_and_store_pool` with `MOET` as default token.
* **Key Assertions**
  * Pool exists script returns `true`.
  * Default reserve registered with zero balance.
  * `PoolCreated` event emitted with correct fields.

## 2. Supported Token Governance Addition
* **Filename**: `token_governance_addition_test.cdc`
* **LOC≈** 70
* **Flow**
  1. Reuse pool from case #1.
  2. Governance admin calls `add_supported_token_simple_interest_curve` for `FlowToken`.
* **Key Assertions**
  * Global ledger lists new token with configured collateral/borrow factors.
  * Attempting to add the same token again **fails** (`beFailed = true`).

## 3. Position Lifecycle – Happy Path
* **Filename**: `position_lifecycle_happy_test.cdc`
* **LOC≈** 90
* **Flow**
  1. Price oracle set to 1.0 FLOW ≙ 1.0.
  2. User mints FLOW and opens position via consumer wrapper (deposit + borrow MOET).
  3. User repays MOET and closes position.
* **Key Assertions**
  * `PositionOpened`, `Borrowed`, `PositionClosed` events observed.
  * Pool's reserve balance increases/decreases correctly.
  * User's MOET balance goes to zero after repayment.

## 4. Rebalance – Undercollateralised Path
* **Filename**: `rebalance_undercollateralised_test.cdc`
* **LOC≈** 80
* **Flow**
  1. Create position as in #3.
  2. Drop oracle price by 20 %.
  3. Call `rebalance_position` with `force=true`.
* **Key Assertions**
  * Health before < 1, health after > before.
  * Top-up executed from user's sink; MOET balance decreases.

## 5. Rebalance – Overcollateralised Path
* **Filename**: `rebalance_overcollateralised_test.cdc`
* **LOC≈** 60 (reuses helper from #4)
* **Flow**
  1. Bump price ↑ 120 % then `rebalance_position`.
* **Key Assertions**
  * Health after < before (excess collateral drawn down).
  * MOET deposited into drawDownSink; user balance increases.

## 6. Reserve Withdrawal Governance Control
* **Filename**: `reserve_withdrawal_test.cdc`
* **LOC≈** 50
* **Flow**
  1. Pool accumulates MOET via prior borrow fees (reuse helper to mint directly to reserve if necessary).
  2. Non-governance account attempts withdrawal → expect **fail**.
  3. Governance admin withdraws to treasury account.
* **Key Assertions**
  * Failure path verified with `beFailed=true`.
  * Treasury vault balance increases by withdrawn amount.

---

### Re-usable Fixtures & Scripts
* `setup()` identical across files – deploy contracts + mock oracle.
* Snapshot/reset pattern between logically independent flows.
* `mockPrice(tokenID, price)` helper in test helpers.

Total estimated LOC ≈ **350** spread over 6 test files – aligns with PR size guidance.

---

#### Implementation Order (for the PR)
1. Extend `test_helpers.cdc` with any missing helpers (price mock, event capture convenience) – keep <50 LOC.
2. Add `pool_creation_workflow_test.cdc` & `token_governance_addition_test.cdc` (foundation).
3. Add position lifecycle + rebalance tests (#3-#5).
4. Conclude with governance reserve withdrawal (#6).

Each commit should introduce ≤2 test files to ease code-review. 
