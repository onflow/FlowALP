# FlowALP Top-level Agent Instructions

This document provides top-level information to agents (Claude Code etc.).
**It is loaded into context automatically for all sessions in this repo, so keep it concise!**

# Testing

All Cadence test files are located in:

```
cadence/tests/*_test.cdc
```

## IMPORTANT: Install Dependencies First

**On a fresh clone, you MUST init submodules and install Flow dependencies before running tests:**

```bash
git submodule update --init --recursive
flow deps install
```

## Run All Tests

```bash
./run_tests.sh
```

## Run Individual Test Files

To run a specific test file:

```bash
flow test <path/to/test_file.cdc>
```

**Example:**
```bash
flow test cadence/tests/liquidation_phase1_test.cdc
```

## Run Individual Tests by Name

**IMPORTANT**: To run a specific test function by name, you **must** specify the file path:

```bash
flow test <path/to/test_file.cdc> --name <test_function_name>
```

**Example:**
```bash
# Run a specific test from a multi-test file
flow test cadence/tests/interest_accrual_integration_test.cdc --name test_combined_all_interest_scenarios
```

### Find all tests in a file
```bash
grep "fun test" cadence/tests/interest_accrual_integration_test.cdc
```
