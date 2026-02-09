# FlowCreditMarket Testing Guide

This document explains how to run tests in the FlowCreditMarket project.

## Test Files Location

All Cadence test files are located in:
```
cadence/tests/*_test.cdc
```

## Running Tests

### Run All Tests

There are several ways to run all tests:

**Option 1: Using flow test (recommended for quick testing)**
```bash
flow test
```
This automatically discovers and runs all files matching `**/*_test.cdc`.

**Option 2: With coverage report**
```bash
flow test --cover
```

**Option 3: With detailed coverage (contracts only)**
```bash
flow test --cover --covercode="contracts" --coverprofile="coverage.lcov"
```

**Option 4: Using the test runner script (recommended for CI)**
```bash
./run_tests.sh
```
This script runs each test file individually and cleans the emulator state between tests to avoid contract collisions. It's useful when tests have conflicting contract deployments.

**Option 5: Using make (from FlowActions directory)**
```bash
cd FlowActions
make test
```

### Run Individual Test Files

To run a specific test file:

```bash
flow test <path/to/test_file.cdc>
```

**Examples:**
```bash
flow test cadence/tests/pool_creation_workflow_test.cdc
flow test cadence/tests/interest_accrual_integration_test.cdc
flow test cadence/tests/liquidation_phase1_test.cdc
```

### Run Individual Tests by Name

**IMPORTANT**: To run a specific test function by name, you **must** specify the file path:

```bash
flow test <path/to/test_file.cdc> --name <test_function_name>
```

**Examples:**
```bash
# Run a single test from pool_creation_workflow_test.cdc
flow test cadence/tests/pool_creation_workflow_test.cdc --name testPoolCreationSucceeds

# Run a single test from interest_accrual_integration_test.cdc
flow test cadence/tests/interest_accrual_integration_test.cdc --name test_moet_debit_accrues_interest

# Run a specific test from a multi-test file
flow test cadence/tests/interest_accrual_integration_test.cdc --name test_combined_all_interest_scenarios
```

**Note**: Running `flow test --name <test_name>` without specifying a file will attempt to run all test files in the project and will likely fail due to import conflicts between different test suites.

### Additional Test Options

**Random test execution:**
```bash
flow test --random
```

**Random test execution with seed (for reproducibility):**
```bash
flow test --random --seed 12345
```

**Fork tests from a remote network:**
```bash
flow test --fork mainnet
flow test --fork testnet --fork-height 12345678
```

## Test Configuration

The test configuration is defined in `flow.json`:
- Test contracts are deployed to address `0000000000000007` (testing network)
- Dependencies like DeFiActions use address `0000000000000006`
- Standard Flow contracts (FungibleToken, etc.) use their emulator addresses

## Available Test Files

Current test files in the repository:

**Core Functionality:**
- `pool_creation_workflow_test.cdc` - Pool creation and setup
- `position_lifecycle_happy_test.cdc` - Position lifecycle (deposit/borrow/repay/withdraw)
- `platform_integration_test.cdc` - Platform integration tests

**Interest & Rates:**
- `interest_curve_test.cdc` - Interest rate curve calculations
- `interest_curve_advanced_test.cdc` - Advanced interest curve scenarios
- `interest_accrual_integration_test.cdc` - Interest accrual integration (6 tests)
  - `test_moet_debit_accrues_interest`
  - `test_moet_credit_accrues_interest_with_insurance`
  - `test_flow_debit_accrues_interest`
  - `test_flow_credit_accrues_interest_with_insurance`
  - `test_insurance_deduction_verification`
  - `test_combined_all_interest_scenarios`
- `update_interest_rate_test.cdc` - Interest rate updates
- `stability_fee_rate_test.cdc` - Stability fee rate calculations
- `insurance_rate_test.cdc` - Insurance rate calculations

**Financial Operations:**
- `deposit_capacity_test.cdc` - Deposit capacity constraints
- `reserve_withdrawal_test.cdc` - Reserve withdrawals
- `withdraw_stability_funds_test.cdc` - Stability fund withdrawals
- `zero_debt_withdrawal_test.cdc` - Zero debt position withdrawals

**Health & Liquidation:**
- `funds_available_above_target_health_test.cdc` - Available funds calculations
- `funds_required_for_target_health_test.cdc` - Required funds calculations
- `liquidation_phase1_test.cdc` - Liquidation mechanics (phase 1)
- `insolvency_redemption_test.cdc` - Insolvency and redemption

**Rebalancing:**
- `rebalance_overcollateralised_test.cdc` - Rebalancing overcollateralized positions
- `rebalance_undercollateralised_test.cdc` - Rebalancing undercollateralized positions
- `auto_borrow_behavior_test.cdc` - Automatic borrowing behavior

**Insurance & Stability:**
- `insurance_collection_test.cdc` - Insurance fee collection
- `insurance_collection_formula_test.cdc` - Insurance formula calculations
- `insurance_swapper_test.cdc` - Insurance token swapping
- `stability_collection_test.cdc` - Stability fee collection
- `stability_collection_formula_test.cdc` - Stability fee formulas

**Governance:**
- `governance_parameters_test.cdc` - Governance parameter management
- `token_governance_addition_test.cdc` - Token governance additions
- `cap_test.cdc` - Cap management

**Math & Utilities:**
- `flowcreditmarketmath_pow_test.cdc` - Math library power function tests
- `phase0_pure_math_test.cdc` - Pure math operations
- `MockDexSwapper_quote_test.cdc` - Mock DEX swapper quotes

## Test Structure

Cadence tests follow this pattern:

```cadence
import Test

// Setup function (runs before tests)
access(all) fun setup() {
    // Deploy contracts, initialize state
}

// Test functions (must start with "test")
access(all) fun testSomething() {
    // Arrange, Act, Assert
    Test.assert(condition)
    Test.assertEqual(expected, actual)
}
```

## Common Test Workflows

**Run all tests in a file:**
```bash
flow test cadence/tests/interest_accrual_integration_test.cdc
# Output: Runs all 6 tests in the file
```

**Run a single test from a file:**
```bash
flow test cadence/tests/interest_accrual_integration_test.cdc --name test_moet_debit_accrues_interest
# Output: Runs only the specified test
```

**Find all tests in a file:**
```bash
grep "fun test" cadence/tests/interest_accrual_integration_test.cdc
```

## Troubleshooting

**Contract collision errors:**
If you encounter contract deployment conflicts when running multiple tests, use `./run_tests.sh` which cleans the emulator state between test files.

**Import errors when using --name without file:**
Always specify the file path when using `--name`. Running `flow test --name <test>` without a file will try to run all test files and will fail with import conflicts.

**Fork network issues:**
When testing against a fork, ensure you have network connectivity and the fork host is accessible.

**Coverage reports:**
Coverage reports are saved to `coverage.lcov` by default. Change the filename with `--coverprofile` flag.

## CI/CD

The GitHub Actions workflow (`.github/workflows/cadence_tests.yml`) runs the full test suite on every push and pull request.

## Quick Reference

```bash
# Run all tests
flow test

# Run all tests with coverage
flow test --cover

# Run one test file
flow test cadence/tests/pool_creation_workflow_test.cdc

# Run one specific test (MUST specify file)
flow test cadence/tests/interest_accrual_integration_test.cdc --name test_moet_debit_accrues_interest

# Run tests individually (recommended for CI)
./run_tests.sh
```
