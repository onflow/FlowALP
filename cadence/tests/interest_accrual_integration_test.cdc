import Test
import BlockchainHelpers

import "MOET"
import "FlowToken"
import "FlowALPv1"
import "FlowALPMath"
import "test_helpers.cdc"

// =============================================================================
// Interest Accrual Integration Tests
// =============================================================================
// These tests verify end-to-end interest accrual mechanics across multiple
// tokens and position types. Unlike the advanced tests that verify mathematical
// precision, these integration tests focus on real-world scenarios:
//
// 1. MOET Debit  - Borrowers pay interest on MOET loans
// 2. MOET Credit - LPs earn interest on MOET deposits (minus insurance)
// 3. Flow Debit  - Borrowers pay interest on Flow loans (KinkCurve)
// 4. Flow Credit - LPs earn interest on Flow deposits (minus insurance)
// 5. Insurance   - Verify insurance spread is correctly applied
// 6. Combined    - All four scenarios running simultaneously
//
// Key Differences from Advanced Tests:
// - Tests 2-6 reset to a clean snapshot for independence (Test 1 runs on fresh deployment)
// - Tests multiple tokens (MOET + Flow) with different curve types
// - Uses practical tolerance ranges rather than exact mathematical values
// - Focuses on protocol solvency and insurance mechanics
//
// Interest Rate Configuration:
// - MOET: FixedRateInterestCurve at 4% APY (rate independent of utilization)
// - Flow: KinkInterestCurve with Aave v3 Volatile One parameters
//         (45% optimal utilization, 0% base, 4% slope1, 300% slope2)
// =============================================================================

// Snapshot for state reset between tests (each test starts fresh)
access(all) var snapshot: UInt64 = 0

// =============================================================================
// Interest Rate Parameters
// =============================================================================

// MOET: FixedRateInterestCurve (Spread Model)
// -----------------------------------------------------------------------------
// In the spread model, the curve defines the DEBIT rate (what borrowers pay).
// The CREDIT rate is derived as: creditRate = debitRate - insuranceRate
// This ensures lenders always earn less than borrowers pay, with the
// difference going to the insurance pool for protocol solvency.
//
// Example at 4% debit rate with 0.1% insurance:
// - Borrowers pay: 4.0% APY
// - Lenders earn:  3.9% APY
// - Insurance:     0.1% APY (collected by protocol)
access(all) let moetFixedRate: UFix128 = 0.04  // 4% APY debit rate

// FlowToken: KinkInterestCurve (Aave v3 Volatile One Parameters)
// -----------------------------------------------------------------------------
// The kink curve adjusts rates based on pool utilization to incentivize
// balanced supply/demand. Below optimal utilization, rates rise slowly.
// Above optimal, rates rise steeply to discourage over-borrowing.
//
// Rate Formula:
// - If utilization ≤ optimal: rate = baseRate + (utilization/optimal) × slope1
// - If utilization > optimal: rate = baseRate + slope1 + ((util-optimal)/(1-optimal)) × slope2
//
// At 40% utilization (below 45% optimal):
// - Rate = 0% + (40%/45%) × 4% ≈ 3.56% APY
//
// At 80% utilization (above 45% optimal):
// - Rate = 0% + 4% + ((80%-45%)/(100%-45%)) × 300% ≈ 195% APY
access(all) let flowOptimalUtilization: UFix128 = 0.45  // 45% kink point
access(all) let flowBaseRate: UFix128 = 0.0             // 0% base rate
access(all) let flowSlope1: UFix128 = 0.04              // 4% slope below kink
access(all) let flowSlope2: UFix128 = 3.0               // 300% slope above kink

// =============================================================================
// Test Setup
// =============================================================================
// Deploys all required contracts and captures a snapshot for test isolation.
// Test 1 runs on the fresh deployment; Tests 2-6 reset to this snapshot.
// =============================================================================
access(all)
fun setup() {
    deployContracts()

    // Capture snapshot AFTER deployment for clean test resets
    snapshot = getCurrentBlockHeight()
}

// =============================================================================
// Test 1: MOET Debit - Interest Accrual Decreases Health Over Time
// =============================================================================
// This test verifies the fundamental borrower experience: as time passes,
// debt grows due to interest, which reduces the position's health factor.
//
// Scenario:
// - LP deposits 10,000 MOET (provides liquidity for borrowing)
// - Borrower deposits 1,000 FLOW collateral and auto-borrows MOET
// - Time advances 30 days
// - Verify: debt increased, health decreased, growth rate is reasonable
//
// Key Insight: Health Factor = Collateral Value / Debt Value
// As debt grows (numerator stays same, denominator increases), health drops.
// =============================================================================
access(all)
fun test_moet_debit_accrues_interest() {
    // -------------------------------------------------------------------------
    // STEP 1: Initialize Protocol Environment
    // -------------------------------------------------------------------------
    // Set up the price oracle with 1:1 FLOW price for simple calculations.
    // This means 1,000 FLOW = $1,000 collateral value.
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)

    // Create the lending pool that will manage all positions.
    // MOET is the default token (the primary borrowable asset).
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)

    // -------------------------------------------------------------------------
    // STEP 2: Configure FlowToken as Collateral
    // -------------------------------------------------------------------------
    // Add FlowToken support with KinkCurve parameters.
    // - collateralFactor: 0.8 = borrowers can borrow up to 80% of collateral value
    // - borrowFactor: 1.0 = no penalty on borrow value calculations
    // The KinkCurve parameters define Flow's interest rate (for Flow borrowing).
    addSupportedTokenKinkCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        optimalUtilization: flowOptimalUtilization,
        baseRate: flowBaseRate,
        slope1: flowSlope1,
        slope2: flowSlope2,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // -------------------------------------------------------------------------
    // STEP 3: Create Liquidity Provider (LP)
    // -------------------------------------------------------------------------
    // The LP deposits MOET into the pool, providing the liquidity that
    // borrowers will borrow from. Without this deposit, there would be
    // no MOET available to borrow.
    let liquidityProvider = Test.createAccount()
    setupMoetVault(liquidityProvider, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: liquidityProvider.address, amount: 10_000.0, beFailed: false)

    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, liquidityProvider)

    // Create LP's position (ID = 0) by depositing MOET.
    // The `false` parameter means no auto-borrow - LP is just supplying liquidity.
    let createLpPosRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [10_000.0, MOET.VaultStoragePath, false],
        liquidityProvider
    )
    Test.expect(createLpPosRes, Test.beSucceeded())
    log("Liquidity provider deposited 10,000 MOET")

    // -------------------------------------------------------------------------
    // STEP 4: Configure MOET Interest Rate
    // -------------------------------------------------------------------------
    // Set MOET to use a FixedRateInterestCurve at 4% APY.
    // This rate is independent of utilization - borrowers always pay 4%.
    // Note: Interest curve must be set AFTER LP deposit to ensure credit exists.
    setInterestCurveFixed(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        yearlyRate: moetFixedRate
    )
    log("Set MOET interest rate to 4% APY (after LP deposit)")

    let res = setInsuranceSwapper(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    let setInsRes = setInsuranceRate(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        insuranceRate: 0.001,
    )
    Test.expect(setInsRes, Test.beSucceeded())

    // -------------------------------------------------------------------------
    // STEP 5: Create Borrower Position
    // -------------------------------------------------------------------------
    // The borrower deposits FLOW as collateral and auto-borrows MOET.
    // With 80% collateral factor and 1:1 price:
    // - 1,000 FLOW = $1,000 collateral
    // - Max borrow = $800 MOET
    // - Auto-borrow targets health factor ~1.3, so borrows less than max
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    mintFlow(to: borrower, amount: 1_000.0)

    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, borrower)

    // Create borrower's position (ID = 1) with auto-borrow enabled (`true`).
    let openRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [1_000.0, FLOW_VAULT_STORAGE_PATH, true],
        borrower
    )
    Test.expect(openRes, Test.beSucceeded())
    log("Borrower deposited 1,000 Flow and auto-borrowed MOET")

    // Position IDs: LP = 0, Borrower = 1
    let borrowerPid: UInt64 = 1

    // -------------------------------------------------------------------------
    // STEP 6: Record Initial State (T = 0)
    // -------------------------------------------------------------------------
    // Capture the borrower's debt and health before any time passes.
    // This serves as the baseline for measuring interest accrual.
    let detailsBefore = getPositionDetails(pid: borrowerPid, beFailed: false)
    let healthBefore = detailsBefore.health
    let debtBefore = getDebitBalanceForType(details: detailsBefore, vaultType: Type<@MOET.Vault>())
    let timestampBefore = getBlockTimestamp()

    log("=== BEFORE TIME ADVANCEMENT ===")
    log("Block timestamp: \(timestampBefore.toString())")
    log("Borrower health: \(healthBefore.toString())")
    log("Borrower MOET debt: \(debtBefore.toString())")

    // Sanity check: auto-borrow should have created debt
    Test.assert(debtBefore > 0.0, message: "Expected position to have MOET debt after auto-borrow")

    // =========================================================================
    // STEP 7: Advance Time by 30 Days
    // =========================================================================
    // Move the blockchain clock forward by 30 days (2,592,000 seconds).
    // During this time, interest will accrue on the borrower's debt.
    //
    // The protocol uses per-second discrete compounding:
    // FinalDebt = InitialDebt × (1 + r/31_557_600)^seconds
    // where r is the annual rate and 31_557_600 is seconds per year (365.25 days).
    Test.moveTime(by: THIRTY_DAYS)
    Test.commitBlock()

    // Verify the time actually advanced by ~30 days
    let timestampAfter = getBlockTimestamp()
    let timeDelta = timestampAfter - timestampBefore
    log("Block timestamp after moveTime: \(timestampAfter.toString())")
    log("Time delta: \(timeDelta.toString())")
    Test.assert(
        timeDelta >= 2591990.0 && timeDelta <= 2592010.0,
        message: "Time delta should be ~2592000 seconds (30 days). Actual: \(timeDelta.toString())"
    )

    // -------------------------------------------------------------------------
    // STEP 8: Record State After Time Advancement
    // -------------------------------------------------------------------------
    // Query the position BEFORE rebalance to capture the raw interest accrual.
    // Scripts compute interest indices transiently based on current timestamp.
    let detailsAfterTime = getPositionDetails(pid: borrowerPid, beFailed: false)
    let healthAfterTime = detailsAfterTime.health
    let debtAfterTime = getDebitBalanceForType(details: detailsAfterTime, vaultType: Type<@MOET.Vault>())

    log("=== AFTER TIME ADVANCEMENT (30 days, before rebalance) ===")
    log("Borrower health: \(healthAfterTime.toString())")
    log("Borrower MOET debt: \(debtAfterTime.toString())")

    // -------------------------------------------------------------------------
    // STEP 9: Trigger Rebalance (Optional - For Completeness)
    // -------------------------------------------------------------------------
    // Rebalance persists interest accrual to storage and may auto-repay debt
    // to restore health. We use pre-rebalance values for assertions since
    // rebalance can modify debt amounts.
    rebalancePosition(signer: PROTOCOL_ACCOUNT, pid: borrowerPid, force: true, beFailed: false)

    let detailsAfter = getPositionDetails(pid: borrowerPid, beFailed: false)
    let healthAfter = detailsAfter.health
    let debtAfter = getDebitBalanceForType(details: detailsAfter, vaultType: Type<@MOET.Vault>())

    log("=== AFTER REBALANCE ===")
    log("Borrower health: \(healthAfter.toString())")
    log("Borrower MOET debt: \(debtAfter.toString())")

    // =========================================================================
    // ASSERTIONS: Verify Interest Accrual Behavior
    // =========================================================================

    // Assertion 1: Debt must have increased from interest accrual
    Test.assert(
        debtAfterTime > debtBefore,
        message: "Expected debt to increase from interest accrual. Before: \(debtBefore.toString()), After (pre-rebalance): \(debtAfterTime.toString())"
    )

    // Assertion 2: Health must have decreased (debt up, collateral unchanged)
    Test.assert(
        healthAfterTime < healthBefore,
        message: "Expected health to decrease as debt accrues interest. Before: \(healthBefore.toString()), After (pre-rebalance): \(healthAfterTime.toString())"
    )

    // Assertion 3: Growth rate should be in reasonable range
    let debtGrowth = debtAfterTime - debtBefore
    let growthRate = debtGrowth / debtBefore
    log("Debt growth: \(debtGrowth.toString())")
    log("Growth rate (30 days): \(growthRate.toString())")

    // -------------------------------------------------------------------------
    // Expected Growth Calculation
    // -------------------------------------------------------------------------
    // Per-second compounding: (1 + r / 31_557_600) ^ seconds - 1
    // At 4% APY for 30 days (2,592,000 seconds):
    // Growth = (1 + 0.04 / 31_557_600) ^ 2_592_000 - 1 ≈ 0.328%
    //
    // We use a wide tolerance range because:
    // 1. Actual utilization affects some curve types
    // 2. Block timing can vary slightly
    // 3. We're testing integration, not mathematical precision
    let minExpectedGrowth: UFix64 = 0.002   // 0.2% (conservative lower bound)
    let maxExpectedGrowth: UFix64 = 0.015   // 1.5% (allowing for edge cases)

    Test.assert(
        growthRate >= minExpectedGrowth && growthRate <= maxExpectedGrowth,
        message: "Interest growth rate \(growthRate.toString()) outside expected range [\(minExpectedGrowth.toString()), \(maxExpectedGrowth.toString())]"
    )

    log("=== TEST PASSED ===")
    log("Interest accrual correctly increased debt and decreased health over 30 days")
}

// =============================================================================
// Test 2: MOET Credit - LP Earns Interest With Insurance Deduction
// =============================================================================
// This test verifies the lender experience: LPs earn interest on their deposits,
// but at a rate LOWER than what borrowers pay. The difference is the "insurance
// spread" - retained by the protocol for risk management and solvency.
//
// Scenario:
// - LP deposits 10,000 MOET (earns credit interest)
// - Borrower deposits 10,000 FLOW and borrows MOET (creates utilization)
// - Time advances 30 days
// - Verify: LP credit increased, growth rate is in expected range
//
// Key Insight (FixedRateInterestCurve Spread Model):
// - debitRate = 4.0% (what borrowers pay, defined by curve)
// - insuranceRate = 0.1% (protocol reserve)
// - creditRate = debitRate - insuranceRate = 3.9% (what lenders earn)
// =============================================================================
access(all)
fun test_moet_credit_accrues_interest_with_insurance() {
    // -------------------------------------------------------------------------
    // STEP 1: Reset to Clean State
    // -------------------------------------------------------------------------
    // Each integration test starts fresh to ensure independence.
    // This prevents test order dependencies and makes debugging easier.
    Test.reset(to: snapshot)

    // -------------------------------------------------------------------------
    // STEP 2: Initialize Protocol Environment
    // -------------------------------------------------------------------------
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)

    // Add FlowToken as collateral (needed for borrower to borrow MOET)
    addSupportedTokenKinkCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        optimalUtilization: flowOptimalUtilization,
        baseRate: flowBaseRate,
        slope1: flowSlope1,
        slope2: flowSlope2,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // -------------------------------------------------------------------------
    // STEP 3: Create Liquidity Provider (LP)
    // -------------------------------------------------------------------------
    // The LP deposits MOET and will earn credit interest over time.
    // This is the position we're testing for interest accrual.
    let lp = Test.createAccount()
    setupMoetVault(lp, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: lp.address, amount: 10_000.0, beFailed: false)

    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, lp)

    // Create LP's position (ID = 0) with MOET deposit
    let createLpPosRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [10_000.0, MOET.VaultStoragePath, false],
        lp
    )
    Test.expect(createLpPosRes, Test.beSucceeded())
    log("LP deposited 10,000 MOET")

    // -------------------------------------------------------------------------
    // STEP 4: Configure MOET Interest Rate
    // -------------------------------------------------------------------------
    // Set 4% APY debit rate. Credit rate will be ~3.9% after insurance deduction.
    setInterestCurveFixed(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        yearlyRate: moetFixedRate
    )

    let res = setInsuranceSwapper(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    let setInsRes = setInsuranceRate(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        insuranceRate: 0.01,
    )
    Test.expect(setInsRes, Test.beSucceeded())

    // -------------------------------------------------------------------------
    // STEP 5: Create Borrower to Generate Utilization
    // -------------------------------------------------------------------------
    // For the LP to earn interest, there must be borrowers paying interest.
    // The borrower creates "utilization" - the ratio of borrowed to deposited.
    // Note: For FixedRateInterestCurve (MOET), the credit rate is independent
    // of utilization. For KinkCurve, higher utilization means higher rates.
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    mintFlow(to: borrower, amount: 10_000.0)

    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, borrower)

    // Borrower deposits FLOW collateral and auto-borrows MOET
    // This creates utilization in the MOET pool
    let openRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [10_000.0, FLOW_VAULT_STORAGE_PATH, true],
        borrower
    )
    Test.expect(openRes, Test.beSucceeded())
    log("Borrower deposited 10,000 Flow and auto-borrowed MOET")

    // -------------------------------------------------------------------------
    // STEP 6: Record LP's Initial Credit Balance
    // -------------------------------------------------------------------------
    let lpPid: UInt64 = 0
    let lpDetailsBefore = getPositionDetails(pid: lpPid, beFailed: false)
    let lpCreditBefore = getCreditBalanceForType(details: lpDetailsBefore, vaultType: Type<@MOET.Vault>())

    log("=== BEFORE TIME ADVANCEMENT ===")
    log("LP MOET credit: \(lpCreditBefore.toString())")

    // =========================================================================
    // STEP 7: Advance Time by 30 Days
    // =========================================================================
    // During this period, the LP's credit balance will grow as borrowers
    // pay interest. The growth rate should be slightly less than the debit
    // rate due to the insurance spread.
    Test.moveTime(by: THIRTY_DAYS)
    Test.commitBlock()

    // -------------------------------------------------------------------------
    // STEP 8: Record LP's Credit Balance After Time Advancement
    // -------------------------------------------------------------------------
    let lpDetailsAfter = getPositionDetails(pid: lpPid, beFailed: false)
    let lpCreditAfter = getCreditBalanceForType(details: lpDetailsAfter, vaultType: Type<@MOET.Vault>())

    log("=== AFTER TIME ADVANCEMENT (30 days) ===")
    log("LP MOET credit: \(lpCreditAfter.toString())")

    // =========================================================================
    // ASSERTIONS: Verify Credit Interest Accrual
    // =========================================================================

    // Assertion 1: Credit balance must have increased
    Test.assert(
        lpCreditAfter > lpCreditBefore,
        message: "Expected LP credit to increase from interest. Before: \(lpCreditBefore.toString()), After: \(lpCreditAfter.toString())"
    )

    // Assertion 2: Growth rate should be in expected range
    let creditGrowth = lpCreditAfter - lpCreditBefore
    let creditGrowthRate = creditGrowth / lpCreditBefore
    log("Credit growth: \(creditGrowth.toString())")
    log("Credit growth rate (30 days): \(creditGrowthRate.toString())")

    // -------------------------------------------------------------------------
    // Expected Credit Growth Calculation
    // -------------------------------------------------------------------------
    // Debit rate: 4% APY (what borrowers pay)
    // Insurance: 0.1% APY (protocol reserve)
    // Credit rate: 4% - 0.1% = 3.9% APY (what LPs earn)
    //
    // 30-day credit growth ≈ 3.9% × (30/365) ≈ 0.32%
    //
    // We use a range to account for:
    // - Utilization effects (not all MOET is borrowed)
    // - Timing variations
    let minExpectedCreditGrowth: UFix64 = 0.001  // 0.1%
    let maxExpectedCreditGrowth: UFix64 = 0.005  // 0.5%

    Test.assert(
        creditGrowthRate >= minExpectedCreditGrowth && creditGrowthRate <= maxExpectedCreditGrowth,
        message: "Credit growth rate \(creditGrowthRate.toString()) outside expected range [\(minExpectedCreditGrowth.toString()), \(maxExpectedCreditGrowth.toString())]"
    )

    log("=== TEST PASSED ===")
    log("MOET credit accrued interest with insurance deduction")
}

// =============================================================================
// Test 3: Flow Debit - Borrower Pays Flow Interest at KinkCurve Rate
// =============================================================================
// This test verifies that borrowing a NON-DEFAULT token (Flow) also accrues
// interest correctly. Unlike MOET which uses FixedRateInterestCurve, Flow uses
// a KinkInterestCurve where the rate depends on pool utilization.
//
// Scenario:
// - LP deposits 10,000 FLOW (provides Flow liquidity)
// - Borrower deposits 10,000 MOET as collateral
// - Borrower borrows 4,000 FLOW (creates 40% utilization)
// - Time advances 30 days
// - Verify: Flow debt increased, health decreased
//
// Key Insight (KinkInterestCurve):
// At 40% utilization (below 45% optimal kink):
// - Rate = baseRate + (utilization/optimal) × slope1
// - Rate = 0% + (40%/45%) × 4% ≈ 3.56% APY
// =============================================================================
access(all)
fun test_flow_debit_accrues_interest() {
    // -------------------------------------------------------------------------
    // STEP 1: Reset to Clean State
    // -------------------------------------------------------------------------
    Test.reset(to: snapshot)

    // -------------------------------------------------------------------------
    // STEP 2: Initialize Protocol Environment
    // -------------------------------------------------------------------------
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)

    // Add FlowToken with KinkCurve parameters
    addSupportedTokenKinkCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        optimalUtilization: flowOptimalUtilization,
        baseRate: flowBaseRate,
        slope1: flowSlope1,
        slope2: flowSlope2,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // -------------------------------------------------------------------------
    // STEP 3: Create Flow Liquidity Provider
    // -------------------------------------------------------------------------
    // This LP deposits FLOW, providing the liquidity that the borrower will
    // borrow from. Without this, there would be no FLOW to borrow.
    let flowLp = Test.createAccount()
    setupMoetVault(flowLp, beFailed: false)
    mintFlow(to: flowLp, amount: 10_000.0)

    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, flowLp)

    // Create LP's position (ID = 0) with Flow deposit
    let createLpPosRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [10_000.0, FLOW_VAULT_STORAGE_PATH, false],
        flowLp
    )
    Test.expect(createLpPosRes, Test.beSucceeded())
    log("Flow LP deposited 10,000 Flow")

    // -------------------------------------------------------------------------
    // STEP 4: Configure Flow Interest Curve
    // -------------------------------------------------------------------------
    // Set the KinkInterestCurve for Flow. The rate will vary based on
    // utilization, with a "kink" at 45% where the slope increases dramatically.
    // Note: Must be set AFTER LP deposit (totalCreditBalance > 0 required).
    setInterestCurveKink(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        optimalUtilization: flowOptimalUtilization,
        baseRate: flowBaseRate,
        slope1: flowSlope1,
        slope2: flowSlope2
    )

    let res = setInsuranceSwapper(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    let setInsRes = setInsuranceRate(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        insuranceRate: 0.01,
    )
    Test.expect(setInsRes, Test.beSucceeded())

    // -------------------------------------------------------------------------
    // STEP 5: Create Borrower Who Borrows Flow
    // -------------------------------------------------------------------------
    // The borrower deposits MOET as collateral (not Flow), then explicitly
    // borrows Flow. This is different from Test 1 where auto-borrow was used.
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: borrower.address, amount: 10_000.0, beFailed: false)

    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, borrower)

    // Step 5a: Create position with MOET collateral (no auto-borrow)
    let createPosRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [10_000.0, MOET.VaultStoragePath, false],
        borrower
    )
    Test.expect(createPosRes, Test.beSucceeded())

    // Step 5b: Explicitly borrow Flow from the position
    // Borrowing 4,000 FLOW from 10,000 FLOW pool = 40% utilization
    let borrowPid: UInt64 = 1
    let borrowRes = executeTransaction(
        "./transactions/position-manager/borrow_from_position.cdc",
        [borrowPid, FLOW_TOKEN_IDENTIFIER, 4_000.0],
        borrower
    )
    Test.expect(borrowRes, Test.beSucceeded())
    log("Borrower deposited 10,000 MOET and borrowed 4,000 Flow")

    // -------------------------------------------------------------------------
    // STEP 6: Record Initial State
    // -------------------------------------------------------------------------
    let borrowerDetailsBefore = getPositionDetails(pid: borrowPid, beFailed: false)
    let flowDebtBefore = getDebitBalanceForType(details: borrowerDetailsBefore, vaultType: Type<@FlowToken.Vault>())
    let healthBefore = borrowerDetailsBefore.health

    log("=== BEFORE TIME ADVANCEMENT ===")
    log("Borrower Flow debt: \(flowDebtBefore.toString())")
    log("Borrower health: \(healthBefore.toString())")

    Test.assert(flowDebtBefore > 0.0, message: "Expected position to have Flow debt")

    // =========================================================================
    // STEP 7: Advance Time by 30 Days
    // =========================================================================
    // The Flow debt will grow according to the KinkCurve rate.
    // At 40% utilization (below 45% kink), the rate is relatively low.
    Test.moveTime(by: THIRTY_DAYS)
    Test.commitBlock()

    // -------------------------------------------------------------------------
    // STEP 8: Record Final State
    // -------------------------------------------------------------------------
    let borrowerDetailsAfter = getPositionDetails(pid: borrowPid, beFailed: false)
    let flowDebtAfter = getDebitBalanceForType(details: borrowerDetailsAfter, vaultType: Type<@FlowToken.Vault>())
    let healthAfter = borrowerDetailsAfter.health

    log("=== AFTER TIME ADVANCEMENT (30 days) ===")
    log("Borrower Flow debt: \(flowDebtAfter.toString())")
    log("Borrower health: \(healthAfter.toString())")

    // =========================================================================
    // ASSERTIONS: Verify Flow Debit Interest Accrual
    // =========================================================================

    // Assertion 1: Flow debt must have increased
    Test.assert(
        flowDebtAfter > flowDebtBefore,
        message: "Expected Flow debt to increase. Before: \(flowDebtBefore.toString()), After: \(flowDebtAfter.toString())"
    )

    // Assertion 2: Health must have decreased (debt up, collateral unchanged)
    Test.assert(
        healthAfter < healthBefore,
        message: "Expected health to decrease. Before: \(healthBefore.toString()), After: \(healthAfter.toString())"
    )

    // Assertion 3: Growth rate should be in expected range
    let debtGrowth = flowDebtAfter - flowDebtBefore
    let debtGrowthRate = debtGrowth / flowDebtBefore
    log("Flow debt growth: \(debtGrowth.toString())")
    log("Flow debt growth rate (30 days): \(debtGrowthRate.toString())")

    // -------------------------------------------------------------------------
    // Expected Growth Calculation (KinkCurve)
    // -------------------------------------------------------------------------
    // Utilization = 4,000 / 10,000 = 40% (below 45% optimal)
    // Rate = baseRate + (util/optimal) × slope1
    //      = 0% + (40%/45%) × 4% ≈ 3.56% APY
    //
    // 30-day growth ≈ 3.56% × (30/365) ≈ 0.29%
    let minExpectedDebtGrowth: UFix64 = 0.002  // 0.2%
    let maxExpectedDebtGrowth: UFix64 = 0.010  // 1.0%

    Test.assert(
        debtGrowthRate >= minExpectedDebtGrowth && debtGrowthRate <= maxExpectedDebtGrowth,
        message: "Flow debt growth rate \(debtGrowthRate.toString()) outside expected range [\(minExpectedDebtGrowth.toString()), \(maxExpectedDebtGrowth.toString())]"
    )

    log("=== TEST PASSED ===")
    log("Flow debit accrued interest at KinkCurve rate")
}

// =============================================================================
// Test 4: Flow Credit - LP Earns Flow Interest With Insurance Deduction
// =============================================================================
// This test verifies the insurance spread mechanism for Flow (KinkCurve).
// The LP earns interest on their Flow deposit, but at a rate lower than
// what borrowers pay. This ensures protocol solvency.
//
// Scenario:
// - LP deposits 10,000 FLOW (earns credit interest)
// - Borrower deposits 10,000 MOET and borrows 4,000 FLOW
// - Time advances 30 days
// - Verify: LP credit increased, credit growth < debt growth (insurance spread)
//
// Key Insight (Reserve Factor):
// For KinkCurve, the protocol retains a "reserve factor" from borrower interest.
// Total interest paid by borrowers = Interest to LPs + Reserve to protocol
// =============================================================================
access(all)
fun test_flow_credit_accrues_interest_with_insurance() {
    // -------------------------------------------------------------------------
    // STEP 1: Reset to Clean State
    // -------------------------------------------------------------------------
    Test.reset(to: snapshot)

    // -------------------------------------------------------------------------
    // STEP 2: Initialize Protocol Environment
    // -------------------------------------------------------------------------
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)

    // Add FlowToken with KinkCurve
    addSupportedTokenKinkCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        optimalUtilization: flowOptimalUtilization,
        baseRate: flowBaseRate,
        slope1: flowSlope1,
        slope2: flowSlope2,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // -------------------------------------------------------------------------
    // STEP 3: Create Flow Liquidity Provider
    // -------------------------------------------------------------------------
    // This LP's credit balance is what we're testing for interest accrual.
    let flowLp = Test.createAccount()
    setupMoetVault(flowLp, beFailed: false)
    mintFlow(to: flowLp, amount: 10_000.0)

    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, flowLp)

    // Create LP's position (ID = 0) with Flow deposit
    let createLpPosRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [10_000.0, FLOW_VAULT_STORAGE_PATH, false],
        flowLp
    )
    Test.expect(createLpPosRes, Test.beSucceeded())
    log("Flow LP deposited 10,000 Flow")

    // -------------------------------------------------------------------------
    // STEP 4: Configure Flow Interest Curve
    // -------------------------------------------------------------------------
    setInterestCurveKink(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        optimalUtilization: flowOptimalUtilization,
        baseRate: flowBaseRate,
        slope1: flowSlope1,
        slope2: flowSlope2
    )

    let res = setInsuranceSwapper(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    let setInsRes = setInsuranceRate(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        insuranceRate: 0.01,
    )
    Test.expect(setInsRes, Test.beSucceeded())

    // -------------------------------------------------------------------------
    // STEP 5: Create Borrower to Generate Utilization
    // -------------------------------------------------------------------------
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: borrower.address, amount: 10_000.0, beFailed: false)

    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, borrower)

    // Create position with MOET collateral
    let createPosRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [10_000.0, MOET.VaultStoragePath, false],
        borrower
    )
    Test.expect(createPosRes, Test.beSucceeded())

    // Borrow 4,000 Flow (40% utilization)
    let borrowPid: UInt64 = 1
    let borrowRes = executeTransaction(
        "./transactions/position-manager/borrow_from_position.cdc",
        [borrowPid, FLOW_TOKEN_IDENTIFIER, 4_000.0],
        borrower
    )
    Test.expect(borrowRes, Test.beSucceeded())
    log("Borrower deposited 10,000 MOET and borrowed 4,000 Flow")

    // -------------------------------------------------------------------------
    // STEP 6: Record Initial Balances (Both LP and Borrower)
    // -------------------------------------------------------------------------
    // We track both to compare credit vs debit growth rates.
    let lpPid: UInt64 = 0
    let lpDetailsBefore = getPositionDetails(pid: lpPid, beFailed: false)
    let flowCreditBefore = getCreditBalanceForType(details: lpDetailsBefore, vaultType: Type<@FlowToken.Vault>())

    let borrowerDetailsBefore = getPositionDetails(pid: borrowPid, beFailed: false)
    let flowDebtBefore = getDebitBalanceForType(details: borrowerDetailsBefore, vaultType: Type<@FlowToken.Vault>())

    log("=== BEFORE TIME ADVANCEMENT ===")
    log("LP Flow credit: \(flowCreditBefore.toString())")
    log("Borrower Flow debt: \(flowDebtBefore.toString())")

    // =========================================================================
    // STEP 7: Advance Time by 30 Days
    // =========================================================================
    Test.moveTime(by: THIRTY_DAYS)
    Test.commitBlock()

    // -------------------------------------------------------------------------
    // STEP 8: Record Final Balances
    // -------------------------------------------------------------------------
    let lpDetailsAfter = getPositionDetails(pid: lpPid, beFailed: false)
    let flowCreditAfter = getCreditBalanceForType(details: lpDetailsAfter, vaultType: Type<@FlowToken.Vault>())

    let borrowerDetailsAfter = getPositionDetails(pid: borrowPid, beFailed: false)
    let flowDebtAfter = getDebitBalanceForType(details: borrowerDetailsAfter, vaultType: Type<@FlowToken.Vault>())

    log("=== AFTER TIME ADVANCEMENT (30 days) ===")
    log("LP Flow credit: \(flowCreditAfter.toString())")
    log("Borrower Flow debt: \(flowDebtAfter.toString())")

    // =========================================================================
    // ASSERTIONS: Verify Insurance Spread Mechanism
    // =========================================================================

    // Assertion 1: LP credit must have increased
    Test.assert(
        flowCreditAfter > flowCreditBefore,
        message: "Expected LP Flow credit to increase"
    )

    // Calculate growth rates for comparison
    let creditGrowth = flowCreditAfter - flowCreditBefore
    let creditGrowthRate = creditGrowth / flowCreditBefore
    let debtGrowth = flowDebtAfter - flowDebtBefore
    let debtGrowthRate = debtGrowth / flowDebtBefore

    log("Credit growth rate: \(creditGrowthRate.toString())")
    log("Debt growth rate: \(debtGrowthRate.toString())")

    // -------------------------------------------------------------------------
    // Assertion 2: Credit Growth Rate < Debt Growth Rate (Insurance Spread)
    // -------------------------------------------------------------------------
    // This is the KEY assertion for solvency. If LPs earned more than borrowers
    // paid, the protocol would become insolvent. The reserve factor ensures
    // total credit income < total debit income.
    Test.assert(
        creditGrowthRate < debtGrowthRate,
        message: "Credit growth rate should be less than debt growth rate due to insurance. Credit: \(creditGrowthRate.toString()), Debt: \(debtGrowthRate.toString())"
    )

    log("=== TEST PASSED ===")
    log("Flow credit accrued interest with insurance deduction (credit < debt growth)")
}

// =============================================================================
// Test 5: Insurance Deduction Verification
// =============================================================================
// This test explicitly measures the insurance spread by using exaggerated
// parameters (10% debit rate, 1% insurance) over a full year to make the
// spread clearly measurable.
//
// Scenario:
// - LP deposits 10,000 MOET
// - Borrower deposits 10,000 FLOW and borrows MOET
// - Insurance rate set to 1% (higher than default 0.1% for visibility)
// - Debit rate set to 10% APY
// - Time advances 1 YEAR
// - Verify: Insurance spread ≈ 1% (debit rate - credit rate)
//
// Key Insight (FixedRateInterestCurve Spread Model):
// - debitRate = 10% (what borrowers pay)
// - insuranceRate = 1% (protocol reserve)
// - creditRate = debitRate - insuranceRate = 9% (what LPs earn)
// - Spread = debitRate - creditRate = 1%
// =============================================================================
access(all)
fun test_insurance_deduction_verification() {
    // -------------------------------------------------------------------------
    // STEP 1: Reset to Clean State
    // -------------------------------------------------------------------------
    Test.reset(to: snapshot)

    // -------------------------------------------------------------------------
    // STEP 2: Initialize Protocol Environment
    // -------------------------------------------------------------------------
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)

    // Add FlowToken for collateral
    addSupportedTokenKinkCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        optimalUtilization: flowOptimalUtilization,
        baseRate: flowBaseRate,
        slope1: flowSlope1,
        slope2: flowSlope2,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // -------------------------------------------------------------------------
    // STEP 3: Create Liquidity Provider
    // -------------------------------------------------------------------------
    let lp = Test.createAccount()
    setupMoetVault(lp, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: lp.address, amount: 10_000.0, beFailed: false)

    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, lp)

    let createLpPosRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [10_000.0, MOET.VaultStoragePath, false],
        lp
    )
    Test.expect(createLpPosRes, Test.beSucceeded())

    // -------------------------------------------------------------------------
    // STEP 4: Configure Exaggerated Interest Parameters
    // -------------------------------------------------------------------------
    // We use higher rates than normal to make the insurance spread clearly
    // visible and measurable over a 1-year period.
    //
    // Insurance Rate: 1% (vs default 0.1%)
    // Debit Rate: 10% (vs default 4%)
    // Expected Credit Rate: 10% - 1% = 9%
    let res = setInsuranceSwapper(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    let setRes = setInsuranceRate(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        insuranceRate: 0.01  // 1% insurance rate
    )
    Test.expect(setRes, Test.beSucceeded())

    let highDebitRate: UFix128 = 0.10
    setInterestCurveFixed(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        yearlyRate: highDebitRate
    )
    log("Set MOET: 10% debit rate, 1% insurance rate")

    // -------------------------------------------------------------------------
    // STEP 5: Create Borrower to Generate Utilization
    // -------------------------------------------------------------------------
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    mintFlow(to: borrower, amount: 10_000.0)

    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, borrower)

    let openRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [10_000.0, FLOW_VAULT_STORAGE_PATH, true],
        borrower
    )
    Test.expect(openRes, Test.beSucceeded())

    // -------------------------------------------------------------------------
    // STEP 6: Record Initial Balances
    // -------------------------------------------------------------------------
    let lpPid: UInt64 = 0
    let borrowerPid: UInt64 = 1

    let lpDetailsBefore = getPositionDetails(pid: lpPid, beFailed: false)
    let creditBefore = getCreditBalanceForType(details: lpDetailsBefore, vaultType: Type<@MOET.Vault>())

    let borrowerDetailsBefore = getPositionDetails(pid: borrowerPid, beFailed: false)
    let debtBefore = getDebitBalanceForType(details: borrowerDetailsBefore, vaultType: Type<@MOET.Vault>())

    log("=== BEFORE ===")
    log("LP credit: \(creditBefore.toString())")
    log("Borrower debt: \(debtBefore.toString())")

    // =========================================================================
    // STEP 7: Advance Time by 1 Full Year
    // =========================================================================
    // Using 1 year (31,557,600 seconds for 365.25 days) makes the percentage calculations
    // straightforward. With per-second discrete compounding:
    // - 10% APY → (1 + 0.10 / 31_557_600) ^ 31_557_600 - 1 ≈ 10.52% effective rate
    // - 9% APY → (1 + 0.09 / 31_557_600) ^ 31_557_600 - 1 ≈ 9.42% effective rate
    // - Spread should be approximately 1%
    Test.moveTime(by: ONE_YEAR)
    Test.commitBlock()

    // -------------------------------------------------------------------------
    // STEP 8: Record Final Balances
    // -------------------------------------------------------------------------
    let lpDetailsAfter = getPositionDetails(pid: lpPid, beFailed: false)
    let creditAfter = getCreditBalanceForType(details: lpDetailsAfter, vaultType: Type<@MOET.Vault>())

    let borrowerDetailsAfter = getPositionDetails(pid: borrowerPid, beFailed: false)
    let debtAfter = getDebitBalanceForType(details: borrowerDetailsAfter, vaultType: Type<@MOET.Vault>())

    log("=== AFTER 1 YEAR ===")
    log("LP credit: \(creditAfter.toString())")
    log("Borrower debt: \(debtAfter.toString())")

    // -------------------------------------------------------------------------
    // STEP 9: Calculate and Verify Insurance Spread
    // -------------------------------------------------------------------------
    let creditGrowth = creditAfter - creditBefore
    let debtGrowth = debtAfter - debtBefore
    let actualCreditRate = creditGrowth / creditBefore
    let actualDebtRate = debtGrowth / debtBefore

    log("Actual credit rate (1 year): \(actualCreditRate.toString())")
    log("Actual debt rate (1 year): \(actualDebtRate.toString())")

    // Calculate utilization for reference
    let utilization = debtBefore / creditBefore
    log("Utilization: \(utilization.toString())")

    // =========================================================================
    // ASSERTION: Verify Insurance Spread
    // =========================================================================
    // For FixedRateInterestCurve (spread model):
    // - debitRate = creditRate + insuranceRate
    // - insuranceSpread = debitRate - creditRate ≈ insuranceRate
    //
    // With 10% debit and 1% insurance, spread should be ~1%
    // (Slight variation due to per-second compounding effects)
    let insuranceSpread = actualDebtRate - actualCreditRate
    log("Observed insurance spread: \(insuranceSpread.toString())")

    // Allow tolerance for compounding effects
    Test.assert(
        insuranceSpread >= 0.005 && insuranceSpread <= 0.02,
        message: "Insurance spread should be approximately 1%. Actual: \(insuranceSpread.toString())"
    )

    log("=== TEST PASSED ===")
    log("Insurance deduction verified: spread ≈ 1%")
}

// =============================================================================
// Test 6: Combined - All Four Interest Scenarios Simultaneously
// =============================================================================
// This is the ultimate integration test: it runs all four interest scenarios
// (MOET debit, MOET credit, Flow debit, Flow credit) concurrently in a single
// multi-position scenario. This tests the protocol's ability to handle
// complex, real-world situations with multiple interacting positions.
//
// Position Layout:
// ┌──────────────┬─────────────────┬────────────────┬────────────────────────────────┐
// │ Position     │ Deposits        │ Borrows        │ Interest Effects               │
// ├──────────────┼─────────────────┼────────────────┼────────────────────────────────┤
// │ 0 (LP1)      │ 10,000 MOET     │ -              │ Earns MOET credit              │
// │ 1 (LP2)      │ 5,000 FLOW      │ -              │ Earns Flow credit              │
// │ 2 (Borrower1)│ 2,000 FLOW      │ MOET (auto)    │ Earns Flow credit, Pays MOET   │
// │ 3 (Borrower2)│ 3,000 MOET      │ 2,000 FLOW     │ Earns MOET credit, Pays Flow   │
// └──────────────┴─────────────────┴────────────────┴────────────────────────────────┘
//
// Key Verifications:
// 1. All four balances grow (credits up, debits up)
// 2. Health factors change based on relative interest rates
// 3. Insurance spreads work correctly for both curve types
// 4. Protocol remains solvent (credit income < debit income)
// =============================================================================
access(all)
fun test_combined_all_interest_scenarios() {
    // -------------------------------------------------------------------------
    // STEP 1: Reset to Clean State
    // -------------------------------------------------------------------------
    Test.reset(to: snapshot)

    // -------------------------------------------------------------------------
    // STEP 2: Initialize Protocol Environment
    // -------------------------------------------------------------------------
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)

    // Add FlowToken with KinkCurve
    addSupportedTokenKinkCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        optimalUtilization: flowOptimalUtilization,
        baseRate: flowBaseRate,
        slope1: flowSlope1,
        slope2: flowSlope2,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // =========================================================================
    // STEP 3: Create Position A (LP1) - MOET Liquidity Provider
    // =========================================================================
    // LP1 deposits MOET and will earn MOET credit interest.
    // This provides liquidity for Borrower1 to borrow MOET.
    let moetLp = Test.createAccount()
    setupMoetVault(moetLp, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: moetLp.address, amount: 10_000.0, beFailed: false)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, moetLp)

    let lp1Res = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [10_000.0, MOET.VaultStoragePath, false],
        moetLp
    )
    Test.expect(lp1Res, Test.beSucceeded())
    log("LP1: Deposited 10,000 MOET")

    // =========================================================================
    // STEP 4: Create Position B (LP2) - Flow Liquidity Provider
    // =========================================================================
    // LP2 deposits Flow and will earn Flow credit interest.
    // This provides liquidity for Borrower2 to borrow Flow.
    let flowLp = Test.createAccount()
    setupMoetVault(flowLp, beFailed: false)
    mintFlow(to: flowLp, amount: 5_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, flowLp)

    let lp2Res = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [5_000.0, FLOW_VAULT_STORAGE_PATH, false],
        flowLp
    )
    Test.expect(lp2Res, Test.beSucceeded())
    log("LP2: Deposited 5,000 Flow")

    // -------------------------------------------------------------------------
    // STEP 5: Configure Interest Curves for Both Tokens
    // -------------------------------------------------------------------------
    // MOET: FixedRateInterestCurve at 4% APY (spread model)
    // Flow: KinkInterestCurve with Aave v3 Volatile One parameters
    setInterestCurveFixed(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        yearlyRate: moetFixedRate  // 4% APY
    )
    setInterestCurveKink(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        optimalUtilization: flowOptimalUtilization,
        baseRate: flowBaseRate,
        slope1: flowSlope1,
        slope2: flowSlope2
    )

    let res = setInsuranceSwapper(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    let setInsRes = setInsuranceRate(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        insuranceRate: 0.01,
    )
    Test.expect(setInsRes, Test.beSucceeded())

    // =========================================================================
    // STEP 6: Create Position C (Borrower1) - Flow Collateral, MOET Debt
    // =========================================================================
    // Borrower1 deposits Flow as collateral and auto-borrows MOET.
    // - Collateral: 2,000 FLOW (deposited as credit, earning Flow credit interest)
    // - Debt: MOET (paying MOET debit interest at 4%)
    // - Health Impact: Will DECREASE because debt interest outpaces collateral interest
    //
    // Note: This deposit adds 2,000 FLOW to the pool's credit balance, which
    // affects the utilization calculation for subsequent Flow borrowing.
    let borrower1 = Test.createAccount()
    setupMoetVault(borrower1, beFailed: false)
    mintFlow(to: borrower1, amount: 2_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, borrower1)

    let b1Res = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [2_000.0, FLOW_VAULT_STORAGE_PATH, true],  // auto-borrow MOET
        borrower1
    )
    Test.expect(b1Res, Test.beSucceeded())
    log("Borrower1: Deposited 2,000 Flow, auto-borrowed MOET")

    // =========================================================================
    // STEP 7: Create Position D (Borrower2) - MOET Collateral, Flow Debt
    // =========================================================================
    // Borrower2 deposits MOET as collateral and borrows Flow.
    // - Collateral: 3,000 MOET (deposited as credit, earning MOET credit interest ~3.9%)
    // - Debt: 2,000 FLOW (paying Flow debit interest)
    // - Health Impact: Will INCREASE because collateral interest outpaces debt interest
    //   (3,000 MOET × ~3.9% > 2,000 FLOW × ~2.5% in absolute terms)
    let borrower2 = Test.createAccount()
    setupMoetVault(borrower2, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: borrower2.address, amount: 3_000.0, beFailed: false)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, borrower2)

    let b2PosRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [3_000.0, MOET.VaultStoragePath, false],
        borrower2
    )
    Test.expect(b2PosRes, Test.beSucceeded())

    // Explicitly borrow 2,000 Flow
    // Flow utilization = 2,000 / (5,000 LP2 + 2,000 Borrower1) = 2,000 / 7,000 ≈ 28.6%
    let b2BorrowRes = executeTransaction(
        "./transactions/position-manager/borrow_from_position.cdc",
        [3 as UInt64, FLOW_TOKEN_IDENTIFIER, 2_000.0],
        borrower2
    )
    Test.expect(b2BorrowRes, Test.beSucceeded())
    log("Borrower2: Deposited 3,000 MOET, borrowed 2,000 Flow")

    // -------------------------------------------------------------------------
    // Position ID Summary:
    // -------------------------------------------------------------------------
    // 0 = LP1 (MOET credit)
    // 1 = LP2 (Flow credit)
    // 2 = Borrower1 (MOET debit, Flow collateral)
    // 3 = Borrower2 (Flow debit, MOET collateral)

    // -------------------------------------------------------------------------
    // STEP 8: Record All Initial Balances
    // -------------------------------------------------------------------------
    let lp1Before = getPositionDetails(pid: 0, beFailed: false)
    let lp2Before = getPositionDetails(pid: 1, beFailed: false)
    let b1Before = getPositionDetails(pid: 2, beFailed: false)
    let b2Before = getPositionDetails(pid: 3, beFailed: false)

    let moetCreditBefore = getCreditBalanceForType(details: lp1Before, vaultType: Type<@MOET.Vault>())
    let flowCreditBefore = getCreditBalanceForType(details: lp2Before, vaultType: Type<@FlowToken.Vault>())
    let moetDebtBefore = getDebitBalanceForType(details: b1Before, vaultType: Type<@MOET.Vault>())
    let flowDebtBefore = getDebitBalanceForType(details: b2Before, vaultType: Type<@FlowToken.Vault>())

    let b1HealthBefore = b1Before.health
    let b2HealthBefore = b2Before.health

    log("=== INITIAL STATE ===")
    log("LP1 MOET credit: \(moetCreditBefore.toString())")
    log("LP2 Flow credit: \(flowCreditBefore.toString())")
    log("Borrower1 MOET debt: \(moetDebtBefore.toString())")
    log("Borrower2 Flow debt: \(flowDebtBefore.toString())")
    log("Borrower1 health: \(b1HealthBefore.toString())")
    log("Borrower2 health: \(b2HealthBefore.toString())")

    // =========================================================================
    // STEP 9: Advance Time by 30 Days
    // =========================================================================
    // All four interest types will accrue simultaneously during this period.
    Test.moveTime(by: THIRTY_DAYS)
    Test.commitBlock()

    // -------------------------------------------------------------------------
    // STEP 10: Record All Final Balances
    // -------------------------------------------------------------------------
    let lp1After = getPositionDetails(pid: 0, beFailed: false)
    let lp2After = getPositionDetails(pid: 1, beFailed: false)
    let b1After = getPositionDetails(pid: 2, beFailed: false)
    let b2After = getPositionDetails(pid: 3, beFailed: false)

    let moetCreditAfter = getCreditBalanceForType(details: lp1After, vaultType: Type<@MOET.Vault>())
    let flowCreditAfter = getCreditBalanceForType(details: lp2After, vaultType: Type<@FlowToken.Vault>())
    let moetDebtAfter = getDebitBalanceForType(details: b1After, vaultType: Type<@MOET.Vault>())
    let flowDebtAfter = getDebitBalanceForType(details: b2After, vaultType: Type<@FlowToken.Vault>())

    let b1HealthAfter = b1After.health
    let b2HealthAfter = b2After.health

    log("=== AFTER 30 DAYS ===")
    log("LP1 MOET credit: \(moetCreditAfter.toString())")
    log("LP2 Flow credit: \(flowCreditAfter.toString())")
    log("Borrower1 MOET debt: \(moetDebtAfter.toString())")
    log("Borrower2 Flow debt: \(flowDebtAfter.toString())")
    log("Borrower1 health: \(b1HealthAfter.toString())")
    log("Borrower2 health: \(b2HealthAfter.toString())")

    // =========================================================================
    // ASSERTIONS: Verify All Four Interest Scenarios
    // =========================================================================

    // -------------------------------------------------------------------------
    // Assertion Group 1: All Balances Should Grow
    // -------------------------------------------------------------------------
    // 1. MOET credit increased (LP1)
    Test.assert(moetCreditAfter > moetCreditBefore, message: "LP1 MOET credit should increase")

    // 2. Flow credit increased (LP2)
    Test.assert(flowCreditAfter > flowCreditBefore, message: "LP2 Flow credit should increase")

    // 3. MOET debt increased (Borrower1)
    Test.assert(moetDebtAfter > moetDebtBefore, message: "Borrower1 MOET debt should increase")

    // 4. Flow debt increased (Borrower2)
    Test.assert(flowDebtAfter > flowDebtBefore, message: "Borrower2 Flow debt should increase")

    // -------------------------------------------------------------------------
    // Assertion Group 2: Health Factor Changes
    // -------------------------------------------------------------------------
    // Borrower1 (Flow collateral, MOET debt):
    // - MOET debit rate: 4% APY
    // - Flow credit rate: lower than Flow debit rate due to insurance spread
    // - Net effect: Debt grows faster than collateral → Health DECREASES
    Test.assert(b1HealthAfter < b1HealthBefore, message: "Borrower1 health should decrease")

    // Borrower2 (MOET collateral, Flow debt):
    // - MOET credit rate: ~3.9% APY (4% debit - 0.1% insurance)
    // - Flow debit rate: ~2.5% APY (at 28.6% utilization)
    // - Collateral (3,000 MOET) earning more absolute interest than debt (2,000 Flow)
    // - Net effect: Health INCREASES
    Test.assert(b2HealthAfter > b2HealthBefore, message: "Borrower2 health should increase (collateral interest > debt interest)")

    // -------------------------------------------------------------------------
    // Assertion Group 3: Insurance Spread Verification
    // -------------------------------------------------------------------------
    // Calculate growth rates for MOET
    let moetCreditGrowthRate = (moetCreditAfter - moetCreditBefore) / moetCreditBefore
    let moetDebtGrowthRate = (moetDebtAfter - moetDebtBefore) / moetDebtBefore

    log("MOET credit growth rate: \(moetCreditGrowthRate.toString())")
    log("MOET debt growth rate: \(moetDebtGrowthRate.toString())")

    // For FixedRateInterestCurve: creditRate < debitRate (insurance spread)
    Test.assert(
        moetCreditGrowthRate < moetDebtGrowthRate,
        message: "MOET credit rate should be less than debit rate (insurance spread)"
    )

    // Calculate absolute growth for Flow
    let flowCreditGrowth = flowCreditAfter - flowCreditBefore
    let flowDebtGrowth = flowDebtAfter - flowDebtBefore

    log("Flow credit growth (absolute): \(flowCreditGrowth.toString())")
    log("Flow debt growth (absolute): \(flowDebtGrowth.toString())")

    // For KinkInterestCurve: total credit income < total debit income (reserve factor)
    // This ensures protocol solvency - can't pay out more than collected.
    Test.assert(
        flowCreditGrowth < flowDebtGrowth,
        message: "Flow credit income should be less than debit income (reserve factor)"
    )

    log("=== TEST PASSED ===")
    log("All four interest scenarios verified with insurance spreads")
}
