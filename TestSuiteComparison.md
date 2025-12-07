```bash
git ls-tree --name-only -r origin/feature/tests-and-docs -- cadence/tests
```

```bash
git show origin/feature/tests-and-docs:cadence/tests/test_helpers.cdc | head -n 120
```

Comparison of Test-Suites  
=========================  
Branches reviewed  
• `gio/refactor-pool-creation-updated`  ("current")  
• `feature/tests-and-docs` ("legacy")

The tables/notes below show where the two suites converge and diverge, why the legacy tests were criticised, and what we can salvage when preparing a slim, high-value PR in the future.

────────────────────────────────────────
1. Test-bed Infrastructure
────────────────────────────────────────
Similarity
• Both rely on Flow's `Test` framework and drive Cadence code through `Test.executeScript/Transaction`.
• Both provide a `deployContracts()` helper to bootstrap required contracts.

Key Differences
| Layer | Current branch | Legacy branch |
|-------|----------------|---------------|
| Helper file | `test_helpers.cdc` (≈150 LOC, concise) | `test_helpers.cdc` (≈300 LOC, bespoke utilities) |
| Account/Vault utils | Uses real `FlowTokenStack` & on-chain vault paths; leans on DeFiActions connectors. | Manufactures an in-memory `resource MockVault` to mimic FlowToken; therefore never validates interactions with real vault APIs. |
| Oracle mocks | Separate `MockOracle` contract deployed once during `setup()`. | Builds a string-concat Cadence script at runtime (`createDummyOracle`) and executes it every time a price oracle is needed → fragile and slow. |
| State control | Snapshot + `Test.reset(to:)` isolates cases. | No snapshot/reset; each test implicitly assumes fresh emulator or isolated file. |
| Failure asserts | "`beFailed` flag" pattern allows a single helper to test success & expected-failure flows. | Success only (almost no negative-path coverage). |

Why the complaints?  
• MockVault & string-built oracle mean most calls never exercise FlowCreditMarket's real storage paths or external interfaces. They compile but do **not** detect regressions that would break production flows.  
• Absence of resets makes the file order matter; flaky when run in parallel.

────────────────────────────────────────
2. Breadth vs Depth
────────────────────────────────────────
Legacy branch boasts **28 individual files** covering every buzz-word (governance, oracle, entitlements, rate-limiting, fuzzy testing, …).  
Current branch has **one focused integration file** (`platform_integration_test.cdc`) containing 4 well-scoped scenarios.

Depth comparison (example):

Legacy `position_health_test.cdc`  
```
let health = FlowCreditMarket.calculateHealth(pid: 0)
Test.assert(health >= 0.0)
```
– merely checks non-crash; no collateral / price manipulation.

Current `testUndercollateralizedPositionRebalanceSucceeds`  
• manipulates oracle price,  
• observes MOET balances before & after,  
• forces `rebalance_position` and asserts directional health change – a real behaviour test.

So while legacy suite looks comprehensive, many tests assert only "does not revert/returns boolean". They contributed little signal during reviews.

────────────────────────────────────────
3. Coverage Gaps Identified
────────────────────────────────────────
The **current** suite still lacks:  
• edge-case governance voting,  
• pool factory error paths (duplicate pool, unsupported token),  
• sink/source permissioning,  
• reserve drain prevention.

Interestingly, the **legacy** branch *attempted* some of these (e.g. `access_control_test.cdc`, `rate_limiting_edge_cases_test.cdc`) but in the shallow style. We can rescue their scenario outlines, rewrite them with the modern helpers, and gain meaningful coverage without bloating the PR.

────────────────────────────────────────
4. Relevance Scoring of Legacy Tests
────────────────────────────────────────
(✓ = valuable scenario, ✗ = redundant or superficial)

✓ core_vault_test.cdc – creates pools, deposits/withdraws; needs deeper assertions.  
✓ rate_limiting_edge_cases_test.cdc – good outline for spam/DoS checks.  
✓ attack_vector_tests.cdc – enumerates re-entrancy & flash-loan ideas; missing concrete Cadence calls, but worth porting.  
✗ simple_test.cdc / simple_flowvault_test.cdc – duplicates covered flows.  
✗ fuzzy_testing_comprehensive.cdc – 2 k-line generator that never asserts invariants; skip.  
✗ moet_governance_demo_test.cdc – slideshow-style logging, not an automated test.

────────────────────────────────────────
5. Recommendations for the "right-sized" next PR
────────────────────────────────────────
1. Keep the **current** `platform_integration_test.cdc` as baseline.  
2. Cherry-pick 3–5 high-value scenarios from legacy branch and rewrite them with the modern helper stack:  
   • Governance voting success & failure paths.  
   • Rate-limit enforcement (spam deposit/withdraw).  
   • Attack-vector negative tests (unauthorised sink withdrawal).  
3. For each new test file, enforce:  
   • uses `setup()` + snapshot/reset,  
   • uses real token/Vault paths (FlowTokenStack),  
   • contains at least one behavioural assertion (state change, event emission, invariant).  
4. Target <400 LOC net change per PR (≈2-3 test files) to stay review-friendly.

Adopting this approach will satisfy the prior code-review feedback while maximizing test ROI. 
