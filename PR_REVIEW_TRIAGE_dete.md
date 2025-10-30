### Triage: dete’s review of `cadence/contracts/FlowALP.cdc`

This document summarizes each comment from dete, groups them, and proposes actions.

Legend: [P1]=High priority correctness/API, [P2]=Medium clarity/refactor, [P3]=Low style/docs.

---

## Events and Types
- **Use Type objects in events instead of strings** [P2]
  - Comment: Prefer `Type` over `String` in `Deposited`/`Withdrawn` events.
  - Disposition: Agree. Emit `type: Type` and add helper to stringify for off-chain.
  - Action: Update event fields; adjust emit sites; add script adapter for string output.

## Declarations placement
- **Enums defined at bottom** [P3]
  - Comment: `BalanceDirection` is far down.
  - Disposition: Agree. Move near other core types.
  - Action: Reorder declarations (no logic change).

## Numeric types and ranges
- **Use UFix128 for scaledBalance** [P2]
  - Comment: Consider `UFix128` (when available) instead of `UInt128`.
  - Disposition: Tentative. Today: `UInt128` safeguards magnitude; future: migrate to `UFix128` when stable.
  - Action: Add rationale comments; open follow-up to evaluate `UFix128` in Forte.

- **Why `UInt128` for deposit amounts** [P1]
  - Comment: Deposits/withdrawals are `UFix64`; why `UInt128` in internal functions?
  - Disposition: Agree to change. Use `UFix64` at boundaries; promote internally only when multiplying by indices/rates.
  - Action: Update signatures (`recordDeposit/Withdrawal`) to `UFix64`; convert locally where needed; document each 128-bit use.

- **Overuse of 128-bit types without justification** [P2]
  - Comment: Provide clear reasons per variable.
  - Disposition: Agree.
  - Action: Add sectioned rationale comments and central doc comment explaining 128-bit usage cases.

## Comparison consistency
- **`>` vs `>=` during trueBalance checks** [P1]
  - Comment: Harmonize comparisons in recordDeposit/recordWithdrawal.
  - Disposition: Agree; use `>=` in both.
  - Action: Change comparison or document asymmetry if retained.

## Silent underflow/overflow handling
- **updateCreditBalance/updateDebitBalance clamp-to-zero** [P1]
  - Comment: Silently clamping could hide bugs.
  - Disposition: Agree. Add invariant checks and revert on negative results.
  - Action: Replace clamp with precondition or `panic`/`pre` guard; justify if clamp is required.

## Interest, capacity, and rates
- **Comment quality for enhanced updateInterestIndices** [P3]
  - Comment: Needs clearer comment.
  - Disposition: Agree.
  - Action: Rewrite comment to explain effects and invariants.

- **Inflating deposit capacity over time** [P2]
  - Comment: Seems unnecessary.
  - Disposition: Revisit; likely remove dynamic inflation and rely on health checks.
  - Action: Propose removal or guard with rationale; run tests.

- **Deposit limit function ‘Why?’** [P2]
  - Comment: Justification missing.
  - Disposition: Add rationale or remove.
  - Action: Document purpose; keep if used by UI/alerts; else delete.

- **Unsigned equality check** [P3]
  - Comment: Use `== 0` not `<= 0` for unsigned.
  - Disposition: Agree.
  - Action: Fix condition.

- **Negative credit rate comment wording** [P3]
  - Comment: Prefer explicit wording.
  - Disposition: Agree.
  - Action: Update comment.

- **Insurance calculation review** [P2]
  - Comment: 0.1% of credit balance may need product input.
  - Disposition: Action item to align with product/econ (Jon).
  - Action: Schedule discussion; make constant configurable; add TODO link.

## Phase 0 comments and docstrings
- **Remove or clarify Phase 0 headings** [P3]
  - Disposition: Remove noisy headings; keep docstrings.

- **RiskParams needs comment; liquidation bonus skepticism** [P2]
  - Disposition: Add detailed docs; make liquidation bonus configurable or feature-flagged; revisit econ.

- **More detail for snapshot and position copy types** [P3]
  - Disposition: Expand docstrings with field-level intent.

## Duplication: health/effective value computations
- **Duplicate loops in health computations** [P2]
  - Comment: Same calculation repeated; factor out.
  - Disposition: Agree.
  - Action: Introduce pure helper returning `(effectiveCollateral, effectiveDebt)`; consider `BalanceSheet` utility.

## Withdrawal amount logic
- **Max withdrawal can exceed deposit of a token** [P1]
  - Comment: Multi-collateral case; allow crossing into debt for the token.
  - Disposition: Agree; ensure compute functions support this.
  - Action: Align `fundsAvailableAboveTargetHealth` and `computeAvailableWithdrawal` or deprecate one per duplication note.

- **Top-up vs no top-up path divergence** [P2]
  - Comment: Reuse same logic when no top-up.
  - Disposition: Agree.
  - Action: Refactor to single path with optional source.

## Minor refactors and style
- **Initialize variables after early-returns** [P3]
  - Disposition: Agree.
  - Action: Move inits after zero-amount guards.

- **Split long expressions for readability** [P3]
  - Disposition: Agree.
  - Action: Extract intermediates.

- **Remove awkward one-off variable** [P3]
  - Disposition: Tweak for clarity.

- **Vestigial names mentioning withdrawal** [P3]
  - Disposition: Rename for neutrality.

- **Address/remove TODOs** [P2]
  - Disposition: Resolve or create tracked issues; remove inline TODOs.

## Logging
- **Too much logging for production** [P2]
  - Disposition: Add compile-time or env-guarded logging; remove noisy logs.
  - Action: Wrap logs in `if self.debugLogging` or remove; provide events/scripts instead.

## Health zero guard after withdrawal
- **Suspicious `if self.positionHealth(pid) != 0`** [P1]
  - Comment: Why zero? Should possibly abort or document empty-case.
  - Disposition: Replace with explicit empty-position check; document health semantics (empty=1.0).
  - Action: Update guard and comments; add test.

## Event emission ordering
- **Emit timing doesn’t matter** [P3]
  - Disposition: Minor; can simplify to single line emit after withdraw.

## Drawdown sink behavior
- **Allow sink to reject deposits; code may not revert** [P2]
  - Disposition: Clarify expected behavior; ensure we handle rejection gracefully without revert.
  - Action: Update docs and code to catch/ignore sink rejection or make it configurable.

## Unimplemented getters/setters
- **Target/min/max health stubs** [P1]
  - Disposition: Implement or remove.
  - Action: Implement storage and validation for {min,target,max} health; or remove API.

---

## Proposed Implementation Plan
1. P1 fixes: comparisons, guards, clamp-to-zero invariants, health API stubs, deposit amount types, withdrawal logic correctness.
2. P2 refactors: factor duplicated health math, unify top-up logic, capacity/limit rationale, insurance configurability, numeric rationales, logging guard.
3. P3 cleanup: comments, placement, minor style, event field type.

## Follow-ups / Decisions Needed
- Confirm insurance policy and liquidation bonus with product/econ (Jon).
- Decide on deposit capacity inflation behavior.
- Plan migration for event `type` field schema change.

## Testing
- Add tests for: clamp invariants, multi-collateral over-withdrawals, empty-position health, event type changes, sink rejection handling, unsigned comparisons.


