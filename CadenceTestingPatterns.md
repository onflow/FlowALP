## Cadence Testing Patterns & Best Practices

This document distills the patterns, idioms, and general "know-how" exhibited by the experienced Cadence developer who authored the current test-suite for **FlowALPv0**.  Use it as a practical checklist and style-guide when writing or reviewing Cadence tests.

### 1. Harness, Organisation & Discovery

* **Flow `Test` framework is the nucleus** – Every helper or assertion ultimately calls into `Test.*` functions supplied by the standard testing library (see `flow cadence test`).
* **Flat `access(all)` top-level test functions** – Each test case is a standalone function annotated with `access(all)` so the runner can discover it via reflection:
  ```cadence
  access(all) fun testCreatePoolSucceeds() { /* … */ }
  ```
* **Filename convention** – Suites live under `cadence/tests/`.  A single file (e.g. `platform_integration_test.cdc`) may contain many related cases.
* **Helper modules** – Common utilities are put in sibling files (e.g. `test_helpers.cdc`) and imported via a relative path import string:
  ```cadence
  import "test_helpers.cdc"
  ```

### 2. Contract Deployment Strategy

To guarantee a fresh deterministic state every run we programmatically deploy **all** required contracts in a dedicated `setup()` helper:
```cadence
access(all) fun setup() {
    deployContracts() // calls the shared helper
    // deploy mocks specific to this suite
    var err = Test.deployContract(
        name: "MockOracle",
        path: "../contracts/mocks/MockOracle.cdc",
        arguments: [defaultTokenIdentifier]
    )
    Test.expect(err, Test.beNil())
}
```
Key ideas:
* **Idempotence** – `Test.deployContract` returns an `Error?`; asserting `beNil()` ensures double-deployment fails fast.
* **Batch deployment** – `deployContracts()` (see `test_helpers.cdc`) bundles all global contracts so every suite can reuse the same call.

### 3. Executing Scripts & Transactions

The helpers `_executeScript` and `_executeTransaction` wrap boilerplate:
```cadence
fun _executeScript(path: String, args: [AnyStruct]): Test.ScriptResult {
    return Test.executeScript(Test.readFile(path), args)
}

fun _executeTransaction(path: String, args: [AnyStruct], signer: Test.TestAccount): Test.TransactionResult {
    let txn = Test.Transaction(
        code: Test.readFile(path),
        authorizers: [signer.address],
        signers: [signer],
        arguments: args
    )
    return Test.executeTransaction(txn)
}
```
Patterns extracted:
* **Always read Cadence code from disk** (`Test.readFile`) to avoid string-in-test duplication.
* **Pass arguments as `[AnyStruct]`** to preserve dynamic typing and avoid multiple overload helpers.
* **Validate results immediately** via `Test.expect(result, matcher)` – never silently ignore status codes.

### 4. Assertions & Matchers

* **`Test.expect(actual, matcher)`** – Used for *status* assertions (succeeded/failed) **and** for value equality.
* **`Test.assert(condition)` / `Test.assertEqual(a, b)`** – Simpler boolean/value checks when a dedicated matcher is unnecessary.
* **Explicit failure testing** – Helper signatures accept `beFailed: Bool` so a single helper can assert both success and expected-failure flows:
  ```cadence
  fun setupMoetVault(signer: Test.TestAccount, beFailed: Bool) {
      let res = _executeTransaction(...)
      Test.expect(res, beFailed ? Test.beFailed() : Test.beSucceeded())
  }
  ```

### 5. Blockchain State Control

* **Snapshots** – Capture block height before mutative tests:
  ```cadence
  access(all) var snapshot: UInt64 = 0
  snapshot = getCurrentBlockHeight()
  ```
* **Resets** – Return to snapshot to isolate successive cases:
  ```cadence
  Test.reset(to: snapshot)
  ```
This guarantees *clean* state without redeploying contracts.

### 6. Account & Token Utilities

* **Dynamic test user accounts** via `Test.createAccount()`.
* **Vault setup & minting helpers** – Domain-specific helpers such as `setupMoetVault`, `mintMoet`, `mintFlow` (not shown) abstract repetitive boilerplate.
* **Public balance checks** – Scripts return `UFix64?` which is unwrapped and asserted in tests.

### 7. Mocking Externalities

Real-world dependencies (price oracles, consumer contracts) are replaced by **mock contracts** deployed during setup.  Their behaviour is exposed through test transactions (e.g. `setMockOraclePrice`).  Benefits:
* Deterministic control over state (e.g. simulate collateral price swings).
* Isolated unit tests without hitting live main-net components.

### 8. Reusability Through Parameterisation

Notice how every helper: 
* Accepts the **signer** (`Test.TestAccount`) explicitly.
* Accepts a **`beFailed` boolean** for dual-path testing.
* Accepts **domain parameters** (identifiers, factors, amounts) rather than hard-coded literals.

This provides maximal flexibility for future suites.

### 9. Behaviour-oriented Assertions

The integration tests verify **behavioural invariants** rather than exact numeric values.  Example from `testUndercollateralizedPositionRebalanceSucceeds`:
```cadence
Test.assert(healthAfterPriceChange < healthAfterRebalance)
```
Advantages:
* Less brittle – not tied to implementation details of interest/fee maths.
* Captures intent – positions should get *healthier* after rebalance.

### 10. File & Path Layout

```
cadence/
  contracts/            // source contracts under test
  tests/
    platform_integration_test.cdc  // suite(s)
    test_helpers.cdc               // shared helpers
    transactions/                  // tx files referenced exclusively by tests
  transactions/                    // tx files used by prod & tests
```
Key takeaway: **Keep test-only Cadence under `cadence/tests` so production deployment bundles stay clean.**

### 11. Access Modifiers & Casting

* Helper functions use `access(all)` so any suite can import them.
* When reading script results, cast explicitly:
  ```cadence
  let amount = res.returnValue as! UFix64
  ```
  This fails fast when a wrong type is returned.

### 12. Putting It All Together – A Minimal Skeleton

```cadence
import Test
import "test_helpers.cdc"

access(all) fun setup() {
    deployContracts()
    // plus custom setup
}

access(all) fun testSomething() {
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)

    let txnRes = _executeTransaction(
        "../transactions/some_action.cdc",
        [/* args */],
        user
    )
    Test.expect(txnRes, Test.beSucceeded())
}
```
Use this skeleton as a starting point for any new Cadence test.

---

#### Checklist Before Shipping a Test

1. ❒ Contract deployments covered in `setup()`.
2. ❒ Snapshotted & reset state between logically distinct scenarios.
3. ❒ All expected *failures* asserted using the `beFailed` pattern.
4. ❒ No magic numbers – parameters flow from the test body.
5. ❒ Behavioural assertions preferred over hard-coding results.
6. ❒ All helper code lives in `cadence/tests/test_helpers.cdc` (or sibling).
7. ❒ Imports use relative paths, avoid absolute local paths for portability.

Happy testing!  🚀 
