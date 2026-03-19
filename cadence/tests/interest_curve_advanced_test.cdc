import Test
import BlockchainHelpers

import "MOET"
import "FlowToken"
import "FlowALPv0"
import "FlowALPMath"
import "test_helpers.cdc"

// =============================================================================
// Advanced Interest Curve Tests
// =============================================================================
// These tests verify critical edge cases and mathematical correctness:
// 1. Curve change mid-accrual - verifies old interest is finalized before new curve
// 2. Exact compounding verification - proves compound interest formula is correct
// 3. Rate change between time periods - validates interest segmentation
// =============================================================================

// Snapshot for state reset between tests
access(all) var snapshot: UInt64 = 0

// Snapshot after first test completes (for tests 2-4 which continue from test 1)
access(all) var snapshotAfterTest1: UInt64 = 0

access(all)
fun setup() {
    deployContracts()

    snapshot = getCurrentBlockHeight()
}

// =============================================================================
// Test 1: Curve Change Mid-Accrual with Rate Segmentation
// =============================================================================
// This comprehensive test verifies:
// 1. Interest accrues correctly at initial rate
// 2. Curve change properly finalizes interest at old rate
// 3. Subsequent interest accrues at new rate
// 4. Rate change ratios are mathematically correct
//
// Scenario using a single pool that evolves over time:
// - Phase 1: 10 days at 5% APY
// - Phase 2: 10 days at 15% APY (3x rate)
// - Phase 3: 10 days at 10% APY (2x original rate)
// =============================================================================
access(all)
fun test_curve_change_mid_accrual_and_rate_segmentation() {
    // -------------------------------------------------------------------------
    // STEP 1: Initialize the Protocol Environment
    // -------------------------------------------------------------------------
    // Set up the price oracle with a 1:1 price for FLOW token.
    // This simplifies collateral calculations: 10,000 FLOW = $10,000 collateral value.
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)

    // Create the lending pool that will hold all positions.
    // The pool manages state for both lenders (credit positions) and borrowers (debit positions).
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)

    // -------------------------------------------------------------------------
    // STEP 2: Configure FLOW as a Collateral Asset
    // -------------------------------------------------------------------------
    // Add FlowToken as a supported collateral with a KinkCurve.
    // Parameters explained:
    // - collateralFactor: 0.8 = 80% of FLOW value can be borrowed against
    // - borrowFactor: 1.0 = no additional penalty on borrow value
    // - optimalUtilization: 0.80 = kink point where rate slope increases
    // - slope1/slope2: interest rate slopes before/after the kink
    // - depositRate/Cap: maximum deposit limits for risk management
    addSupportedTokenKinkCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        optimalUtilization: 0.80,
        baseRate: 0.0,
        slope1: 0.04,
        slope2: 0.60,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // -------------------------------------------------------------------------
    // STEP 3: Create a Liquidity Provider (LP)
    // -------------------------------------------------------------------------
    // The LP deposits 100,000 MOET into the pool, providing liquidity
    // that borrowers can borrow from. The LP earns interest on their deposit.
    let lp = Test.createAccount()
    setupMoetVault(lp, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: lp.address, amount: 100_000.0, beFailed: false)

    // Grant beta access (required for protocol interaction during beta phase)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, lp)

    // Create LP's position by depositing MOET.
    // The `false` parameter = not auto-borrowing, just supplying liquidity.
    // This creates position ID 0 (first position in the pool).
    let createLpPosRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [100_000.0, MOET.VaultStoragePath, false],
        lp
    )
    Test.expect(createLpPosRes, Test.beSucceeded())
    log("LP deposited 100,000 MOET")

    // -------------------------------------------------------------------------
    // STEP 4: Set Initial Interest Rate (Phase 1 Configuration)
    // -------------------------------------------------------------------------
    // Configure MOET with a fixed 5% APY interest rate.
    // This is the baseline rate we'll compare other phases against.
    // Using FixedCurve means rate doesn't depend on utilization.
    let rate1: UFix128 = 0.05
    setInterestCurveFixed(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        yearlyRate: rate1
    )
    log("Set MOET interest rate to 5% APY (Phase 1)")

     // set insurance swapper
    let res = setInsuranceSwapper(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    // set insurance rate
    let setInsRes = setInsuranceRate(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        insuranceRate: 0.001,
    )
    Test.expect(setInsRes, Test.beSucceeded())

    // -------------------------------------------------------------------------
    // STEP 5: Create a Borrower
    // -------------------------------------------------------------------------
    // The borrower deposits 10,000 FLOW as collateral and borrows MOET.
    // With 80% collateral factor, max borrow = 8,000 MOET, but auto-borrow targets ~1.3 health.
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    mintFlow(to: borrower, amount: 10_000.0)

    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, borrower)

    // Create borrower's position with auto-borrow enabled (`true` parameter).
    // This deposits FLOW collateral and automatically borrows MOET targeting health factor ~1.3.
    // With 10,000 FLOW × 0.8 collateralFactor / 1.3 healthFactor ≈ 6153.85 MOET borrowed.
    // This creates position ID 1 (second position in the pool).
    let openRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [10_000.0, FLOW_VAULT_STORAGE_PATH, true],
        borrower
    )
    Test.expect(openRes, Test.beSucceeded())
    log("Borrower deposited 10,000 Flow and auto-borrowed MOET")

    // Position ID assignment: LP = 0, Borrower = 1
    let borrowerPid: UInt64 = 1

    // -------------------------------------------------------------------------
    // STEP 6: Record Initial Debt State (T=0)
    // -------------------------------------------------------------------------
    // Capture the borrower's debt at time zero before any interest accrues.
    // This serves as the baseline for measuring interest growth across phases.
    let detailsT0 = getPositionDetails(pid: borrowerPid, beFailed: false)
    let debtT0 = getDebitBalanceForType(details: detailsT0, vaultType: Type<@MOET.Vault>())
    log("=== DAY 0 ===")
    log("Initial debt: \(debtT0.toString())") // 6153.84615384 MOET

    // =========================================================================
    // PHASE 1: 10 Days at 5% APY
    // =========================================================================
    // Advance blockchain time by 10 days and observe interest accrual.
    // Formula: perSecondRate = 1 + 0.05/31_557_600, factor = perSecondRate^864000
    // Expected growth = principal × (factor - 1) ≈ 0.137% of principal
    // The commitBlock() ensures the time change is finalized in the ledger state.
    Test.moveTime(by: TEN_DAYS)
    Test.commitBlock()

    // Query the debt after 10 days to measure Phase 1 interest growth.
    // The protocol calculates interest using discrete per-second compounding.
    let detailsT10 = getPositionDetails(pid: borrowerPid, beFailed: false)
    let debtT10 = getDebitBalanceForType(details: detailsT10, vaultType: Type<@MOET.Vault>())
    let growth1 = debtT10 - debtT0
    log("=== DAY 10 ===")
    log("Debt after 10 days @ 5%: \(debtT10.toString())") // 6162.27607875 MOET
    log("Phase 1 growth: \(growth1.toString())") // 8.42992491 MOET

    // Verify growth1 equals expected value
    // Formula: perSecondRate = 1 + 0.05/31_557_600, factor = perSecondRate^864000
    // Expected: 6153.84615384 * (factor - 1) ≈ 8.42992491 MOET
    let expectedGrowth1: UFix64 = 8.42992491
    let tolerance: UFix64 = 0.0001  // Precision to 0.0001 MOET
    let diff1 = growth1 > expectedGrowth1 ? growth1 - expectedGrowth1 : expectedGrowth1 - growth1
    Test.assert(diff1 <= tolerance, message: "Phase 1 growth should be ~8.42992491. Actual: \(growth1)")

    // -------------------------------------------------------------------------
    // STEP 7: Change Interest Rate to 15% APY (Phase 2 Configuration)
    // -------------------------------------------------------------------------
    // Triple the interest rate to 15% APY. This tests that:
    // 1. Interest accrued at old rate (5%) is finalized before curve change
    // 2. New rate (15%) is applied correctly for subsequent accrual
    // 3. The ratio of growth reflects the ratio of rates (15%/5% = 3x)
    let rate2: UFix128 = 0.15
    setInterestCurveFixed(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        yearlyRate: rate2
    )

    log("Changed MOET interest rate to 15% APY (Phase 2)")

    // =========================================================================
    // PHASE 2: 10 Days at 15% APY
    // =========================================================================
    // Advance another 10 days at the higher rate.
    // Expected: growth2 should be approximately 3x growth1 (since 15%/5% = 3).
    Test.moveTime(by: TEN_DAYS)
    Test.commitBlock()

    let detailsT20 = getPositionDetails(pid: borrowerPid, beFailed: false)
    let debtT20 = getDebitBalanceForType(details: detailsT20, vaultType: Type<@MOET.Vault>())
    let growth2 = debtT20 - debtT10
    log("=== DAY 20 ===")
    log("Debt after 10 days @ 15%: \(debtT20.toString())")
    log("Phase 2 growth: \(growth2.toString())")

    // Verify growth2 equals expected value
    // Formula: perSecondRate = 1 + 0.15/31_557_600, factor = perSecondRate^864000
    // Expected: 6162.27607875 * (factor - 1) ≈ 25.35912505 MOET
    let expectedGrowth2: UFix64 = 25.35912505
    let diff2 = growth2 > expectedGrowth2 ? growth2 - expectedGrowth2 : expectedGrowth2 - growth2
    Test.assert(diff2 <= tolerance, message: "Phase 2 growth should be ~25.35912505. Actual: \(growth2)")

    // -------------------------------------------------------------------------
    // STEP 8: Change Interest Rate to 10% APY (Phase 3 Configuration)
    // -------------------------------------------------------------------------
    // Set rate to 10% (2x the original 5%, 0.67x Phase 2's 15%).
    // This validates that multiple consecutive rate changes work correctly.
    let rate3: UFix128 = 0.10
    setInterestCurveFixed(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        yearlyRate: rate3
    )
    log("Changed MOET interest rate to 10% APY (Phase 3)")

    // =========================================================================
    // PHASE 3: 10 Days at 10% APY
    // =========================================================================
    // Final 10-day period at 10% APY.
    // Expected: growth3 should be approximately 2x growth1 (since 10%/5% = 2).
    Test.moveTime(by: TEN_DAYS)
    Test.commitBlock()

    let detailsT30 = getPositionDetails(pid: borrowerPid, beFailed: false)
    let debtT30 = getDebitBalanceForType(details: detailsT30, vaultType: Type<@MOET.Vault>())
    let growth3 = debtT30 - debtT20
    log("=== DAY 30 ===")
    log("Debt after 10 days @ 10%: \(debtT30.toString())")
    log("Phase 3 growth: \(growth3.toString())")

    // Verify growth3 equals expected value
    // Formula: perSecondRate = 1 + 0.10/31_557_600, factor = perSecondRate^864000
    // Expected: 6187.63520380 * (factor - 1) ≈ 16.96403378 MOET
    let expectedGrowth3: UFix64 = 16.96403378
    let diff3 = growth3 > expectedGrowth3 ? growth3 - expectedGrowth3 : expectedGrowth3 - growth3
    Test.assert(diff3 <= tolerance, message: "Phase 3 growth should be ~16.96403378. Actual: \(growth3)")

    // =========================================================================
    // ASSERTIONS: Verify Rate Ratios Match Growth Ratios
    // =========================================================================
    // The key insight being tested: if the interest rate doubles, the interest
    // growth over the same time period should also approximately double.
    // This proves the curve change properly segments interest accrual at each rate.

    // Assertion 1: Phase 2 (15%) / Phase 1 (5%) should be approximately 3x
    // We allow tolerance (2.5-3.5x) for compounding effects and fixed-point rounding.
    let ratio21 = growth2 / growth1
    log("Phase 2/Phase 1 ratio (should be ~3): \(ratio21.toString())")
    Test.assert(
        ratio21 >= 2.5 && ratio21 <= 3.5,
        message: "Phase 2 growth should be ~3x Phase 1 (15%/5%). Actual ratio: \(ratio21.toString())"
    )

    // Assertion 2: Phase 3 (10%) / Phase 1 (5%) should be approximately 2x
    let ratio31 = growth3 / growth1
    log("Phase 3/Phase 1 ratio (should be ~2): \(ratio31.toString())")
    Test.assert(
        ratio31 >= 1.5 && ratio31 <= 2.5,
        message: "Phase 3 growth should be ~2x Phase 1 (10%/5%). Actual ratio: \(ratio31.toString())"
    )

    // Assertion 3: Phase 2 (15%) / Phase 3 (10%) should be approximately 1.5x
    let ratio23 = growth2 / growth3
    log("Phase 2/Phase 3 ratio (should be ~1.5): \(ratio23.toString())")
    Test.assert(
        ratio23 >= 1.2 && ratio23 <= 1.8,
        message: "Phase 2 growth should be ~1.5x Phase 3 (15%/10%). Actual ratio: \(ratio23.toString())"
    )

    // =========================================================================
    // ASSERTIONS: Verify Interest Accounting Integrity
    // =========================================================================
    // Total interest from day 0 to day 30 should equal the sum of all three phases.
    // This proves no interest is lost or double-counted during curve changes.
    let totalGrowth = debtT30 - debtT0
    let sumOfPhases = growth1 + growth2 + growth3
    let growthDiff = totalGrowth > sumOfPhases
        ? totalGrowth - sumOfPhases
        : sumOfPhases - totalGrowth

    log("Total growth: \(totalGrowth.toString())")
    log("Sum of phases: \(sumOfPhases.toString())")
    log("Difference: \(growthDiff.toString())")

    // Allow small tolerance (< 0.0001) for fixed-point arithmetic rounding
    Test.assert(
        growthDiff < 0.0001,
        message: "Total growth should equal sum of phase growths"
    )

    log("=== TEST PASSED ===")
    log("Multiple rate changes correctly segmented interest accrual")

    // Capture snapshot after test 1 for dependent tests (tests 2-4 build on this state)
    snapshotAfterTest1 = getCurrentBlockHeight()
}

// =============================================================================
// Test 2: Exact Compounding Verification (1 Year)
// =============================================================================
// DEPENDENCY: This test continues from test 1's state (borrower position pid=1).
// This test verifies that the compound interest formula is mathematically correct.
// We continue from the previous test state with established positions.
//
// Formula: FinalBalance = InitialBalance × (1 + r/n)^(n×t) for per-second compounding
// The protocol uses discrete per-second compounding with exponentiation by squaring.
//
// Expected: 10% APY should yield ~10.52% effective rate ((1 + 0.10/31_557_600)^31_557_600 ≈ 1.10517)
// =============================================================================
access(all)
fun test_exact_compounding_verification_one_year() {
    // -------------------------------------------------------------------------
    // TEST DEPENDENCY: This test continues from Test 1's state.
    // The borrower position (pid=1) exists with accumulated debt from the
    // previous 30-day multi-phase test.
    // -------------------------------------------------------------------------

    // Borrower's position ID (created in Test 1)
    let borrowerPid: UInt64 = 1

    // -------------------------------------------------------------------------
    // STEP 1: Configure a Known Interest Rate for Mathematical Verification
    // -------------------------------------------------------------------------
    // Set MOET to exactly 10% APY. This round number makes it easy to verify
    // that the compounding formula is working correctly.
    // 10% APY with per-second compounding yields: (1 + 0.10/31_557_600)^31_557_600 - 1 ≈ 10.517% effective rate
    let yearlyRate: UFix128 = 0.10
    setInterestCurveFixed(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        yearlyRate: yearlyRate
    )
    log("Set MOET interest rate to 10% APY for compounding verification")

    // -------------------------------------------------------------------------
    // STEP 2: Record Starting Debt Before Time Advancement
    // -------------------------------------------------------------------------
    // Capture the current debt balance. This will be our baseline for measuring
    // exactly how much interest accrues over one full year.
    let detailsBefore = getPositionDetails(pid: borrowerPid, beFailed: false)
    let debtBefore = getDebitBalanceForType(details: detailsBefore, vaultType: Type<@MOET.Vault>())

    log("=== BEFORE 1 YEAR ===")
    log("Debt before: \(debtBefore.toString())")

    // -------------------------------------------------------------------------
    // STEP 3: Advance Time by Exactly One Year
    // -------------------------------------------------------------------------
    // Move the blockchain clock forward by 365 days (31,536,000 seconds).
    // This allows us to verify the full annual compounding behavior.
    Test.moveTime(by: ONE_YEAR)
    Test.commitBlock()

    // -------------------------------------------------------------------------
    // STEP 4: Record Final Debt After One Year
    // -------------------------------------------------------------------------
    // Query the debt after exactly one year of interest accrual.
    let detailsAfter = getPositionDetails(pid: borrowerPid, beFailed: false)
    let debtAfter = getDebitBalanceForType(details: detailsAfter, vaultType: Type<@MOET.Vault>())

    log("=== AFTER 1 YEAR ===")
    log("Debt after: \(debtAfter.toString())")

    // -------------------------------------------------------------------------
    // STEP 5: Calculate and Verify the Effective Annual Growth Rate
    // -------------------------------------------------------------------------
    // The growth rate tells us what percentage the debt increased by.
    // This should match the per-second compounding formula: (1 + r/n)^n - 1
    let actualGrowth = debtAfter - debtBefore
    let actualGrowthRate = actualGrowth / debtBefore
    log("Actual growth: \(actualGrowth.toString())")
    log("Actual growth rate: \(actualGrowthRate.toString())")

    // =========================================================================
    // MATHEMATICAL BACKGROUND: Per-Second Compounding
    // =========================================================================
    // Formula: factor = (1 + r/31_557_600)^31_557_600
    // At 10% APY: factor = (1 + 0.10/31_557_600)^31_557_600 ≈ 1.10517092
    // This is discrete per-second compounding with exponentiation by squaring.
    // Note: Using 31557600 seconds/year (365.25 days)
    // =========================================================================

    // -------------------------------------------------------------------------
    // STEP 6: Verify Exact Growth Value
    // -------------------------------------------------------------------------
    // Formula: perSecondRate = 1 + 0.10/31557600, factor = perSecondRate^31557600
    // factor = (1 + 0.10/31557600)^31557600 ≈ 1.105170918
    // Expected growth rate = factor - 1 ≈ 0.105170918
    // Expected growth = debtBefore * (factor - 1) = 6204.59926707 * 0.105170918 ≈ 652.54340074 MOET
    // Note: Tests run sequentially with accumulated interest, so exact values depend on debtBefore

    // Verify growth rate is approximately 10.52% (the effective rate from 10% APY compounded per-second)
    let expectedGrowthRate: UFix64 = 0.10517091
    let expectedGrowth: UFix64 = 652.54340074
    let tolerance: UFix64 = 0.001

    let growthDiff = actualGrowth > expectedGrowth
        ? actualGrowth - expectedGrowth
        : expectedGrowth - actualGrowth
    let rateDiff = actualGrowthRate > expectedGrowthRate
        ? actualGrowthRate - expectedGrowthRate
        : expectedGrowthRate - actualGrowthRate

    log("Expected growth: \(expectedGrowth.toString())")
    log("Growth difference: \(growthDiff.toString())")
    log("Actual growth rate: \(actualGrowthRate.toString())")
    log("Expected growth rate: \(expectedGrowthRate.toString())")

    Test.assert(
        rateDiff <= tolerance,
        message: "Growth rate should be ~0.105170918 (10.52% effective). Actual: \(actualGrowthRate)"
    )
    
     Test.assert(
        growthDiff <= tolerance,
        message: "Growth should be ~652.54340074. Actual: \(actualGrowth)"
    )

    log("=== TEST PASSED ===")
    log("Per-second compounding verified: growth rate ≈ 10.52%")
}

// =============================================================================
// Test 3: Rapid Curve Changes (Same Block Edge Case)
// =============================================================================
// DEPENDENCY: This test continues from test 2's state (borrower position pid=1).
// Verifies that changing the curve multiple times rapidly doesn't cause issues
// (no negative time delta, no double-counting)
// =============================================================================
access(all)
fun test_rapid_curve_changes_no_double_counting() {
    // -------------------------------------------------------------------------
    // TEST DEPENDENCY: This test continues from Test 2's state.
    // The borrower position (pid=1) has accumulated significant debt from
    // the previous tests (30 days at various rates + 1 year at 10%).
    // -------------------------------------------------------------------------

    // =========================================================================
    // EDGE CASE BEING TESTED: Rapid Consecutive Curve Changes
    // =========================================================================
    // This test verifies that changing the interest curve multiple times
    // in rapid succession (within the same block or very close timestamps)
    // does NOT cause:
    // 1. Negative time deltas (which would cause underflow)
    // 2. Double-counting of interest (charging interest multiple times)
    // 3. Lost interest (skipping accrual periods)
    //
    // The expected behavior: when no time passes between curve changes,
    // no interest should accrue between them.
    // =========================================================================

    // Borrower's position ID (created in Test 1)
    let borrowerPid: UInt64 = 1

    // -------------------------------------------------------------------------
    // STEP 1: Record Debt Before Rapid Curve Changes
    // -------------------------------------------------------------------------
    // Capture the current debt as a baseline. After rapid curve changes
    // with no time advancement, the debt should remain essentially unchanged.
    let detailsBefore = getPositionDetails(pid: borrowerPid, beFailed: false)
    let debtBefore = getDebitBalanceForType(details: detailsBefore, vaultType: Type<@MOET.Vault>())

    log("=== BEFORE RAPID CHANGES ===")
    log("Debt: \(debtBefore.toString())")

    // -------------------------------------------------------------------------
    // STEP 2: Execute Multiple Curve Changes Without Time Advancement
    // -------------------------------------------------------------------------
    // Change the curve 3 times in rapid succession. Each curve change should:
    // 1. Finalize any accrued interest at the old rate
    // 2. Set the new curve for future accrual
    //
    // Since no time passes between changes, the interest accrued should be
    // negligible (only from any micro-second differences in timestamps).
    //
    // Sequence: 5% -> 20% -> 10% (final rate)
    setInterestCurveFixed(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, yearlyRate: 0.05)
    setInterestCurveFixed(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, yearlyRate: 0.20)
    setInterestCurveFixed(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER, yearlyRate: 0.10)

    // -------------------------------------------------------------------------
    // STEP 3: Record Debt After Rapid Changes
    // -------------------------------------------------------------------------
    // Query the debt immediately after the rapid curve changes.
    let detailsAfter = getPositionDetails(pid: borrowerPid, beFailed: false)
    let debtAfter = getDebitBalanceForType(details: detailsAfter, vaultType: Type<@MOET.Vault>())

    log("=== AFTER RAPID CHANGES ===")
    log("Debt: \(debtAfter.toString())")

    // -------------------------------------------------------------------------
    // STEP 4: Verify No Significant Interest Accrued
    // -------------------------------------------------------------------------
    // Calculate the growth during the rapid changes. It should be negligible
    // since no meaningful time passed between the curve changes.
    let growth = debtAfter - debtBefore
    let growthRate = growth / debtBefore

    // Verify growth equals expected value
    // Formula: No time passes between curve changes, so no interest should accrue
    // Expected: 0.0 MOET (or negligible due to timing jitter)
    let tolerance: UFix64 = 0.001  // Allow up to 0.001 MOET for timing jitter

    log("Growth from rapid curve changes: \(growth.toString())")
    log("Expected growth: 0.0")
    log("Growth rate: \(growthRate.toString())")
    log("Expected growth rate: 0.0")

    Test.assert(
        growth <= tolerance,
        message: "Growth should be ~0.0. Actual: \(growth)"
    )

    Test.assert(
        growthRate < 0.0001,
        message: "Growth rate should be ~0.0. Actual: \(growthRate)"
    )

    log("=== TEST PASSED ===")
    log("Rapid curve changes handled correctly: no significant interest accrued")
}

// =============================================================================
// Test 4: Credit Rate Also Changes with Curve
// =============================================================================
// DEPENDENCY: This test continues from test 3's state (LP position pid=0).
// Verifies that LP credit balance also responds correctly to curve changes
// =============================================================================
access(all)
fun test_credit_rate_changes_with_curve() {
    // -------------------------------------------------------------------------
    // TEST DEPENDENCY: This test continues from Test 3's state.
    // Both the LP position (pid=0) and borrower position (pid=1) exist
    // with their respective credit and debit balances.
    // -------------------------------------------------------------------------

    // =========================================================================
    // WHAT THIS TEST VERIFIES
    // =========================================================================
    // In a lending protocol, there are two sides to interest:
    // 1. DEBIT interest: What borrowers pay (we tested this in Tests 1-3)
    // 2. CREDIT interest: What lenders (LPs) earn
    //
    // This test verifies that when the interest curve changes, the credit
    // rate paid to LPs also updates correctly. The credit rate is less than
    // the debit rate due to the protocol fee (insurance + stability fee).
    //
    // Formula: creditRate = debitRate * (1 - protocolFeeRate)
    // where protocolFeeRate = insuranceRate + stabilityFeeRate = 0.001 + 0.05 = 0.051
    // Example: At 8% debit rate, credit rate = 8% * 0.949 = 7.592%
    // =========================================================================

    // LP's position ID (created in Test 1, first position in the pool)
    let lpPid: UInt64 = 0

    // -------------------------------------------------------------------------
    // STEP 1: Set a Known Interest Rate for Credit Verification
    // -------------------------------------------------------------------------
    // Configure MOET with 8% APY. This will be the debit rate.
    // The LP should earn slightly less (approximately 7.9% after insurance).
    let testRate: UFix128 = 0.08 // 8% APY
    setInterestCurveFixed(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        yearlyRate: testRate
    )
    log("Set MOET interest rate to 8% APY")

    // -------------------------------------------------------------------------
    // STEP 2: Record LP's Credit Balance Before Time Advancement
    // -------------------------------------------------------------------------
    // Capture the LP's current credit balance (their deposited MOET plus
    // any interest earned so far). This is our baseline for measuring growth.
    let detailsBefore = getPositionDetails(pid: lpPid, beFailed: false)
    let creditBefore = getCreditBalanceForType(details: detailsBefore, vaultType: Type<@MOET.Vault>())

    log("=== BEFORE 30 DAYS ===")
    log("LP Credit: \(creditBefore.toString())")

    // -------------------------------------------------------------------------
    // STEP 3: Advance Time by 30 Days
    // -------------------------------------------------------------------------
    // Move the blockchain clock forward by 30 days to accumulate interest.
    // The LP's credit should grow based on the credit rate.
    Test.moveTime(by: THIRTY_DAYS)
    Test.commitBlock()

    // -------------------------------------------------------------------------
    // STEP 4: Record LP's Credit Balance After 30 Days
    // -------------------------------------------------------------------------
    // Query the LP's credit balance after 30 days of interest accrual.
    let detailsAfter = getPositionDetails(pid: lpPid, beFailed: false)
    let creditAfter = getCreditBalanceForType(details: detailsAfter, vaultType: Type<@MOET.Vault>())

    log("=== AFTER 30 DAYS ===")
    log("LP Credit: \(creditAfter.toString())")

    // -------------------------------------------------------------------------
    // STEP 5: Verify Credit Balance Increased
    // -------------------------------------------------------------------------
    // Sanity check: the LP should always earn positive interest when
    // there's borrowing activity (which there is from the borrower in Test 1).
    Test.assert(
        creditAfter > creditBefore,
        message: "LP credit should increase over time"
    )

    // -------------------------------------------------------------------------
    // STEP 6: Calculate and Verify Credit Growth Rate
    // -------------------------------------------------------------------------
    // Calculate the actual growth rate and compare to expected.
    let creditGrowth = creditAfter - creditBefore
    let creditGrowthRate = creditGrowth / creditBefore

    // Verify credit growth rate equals expected value
    // Formula: creditRate = debitRate * (1 - protocolFeeRate)
    // where protocolFeeRate = insuranceRate + stabilityFeeRate = 0.001 + 0.05 = 0.051
    // creditRate = 0.08 * (1 - 0.051) = 0.08 * 0.949 = 0.07592 APY (7.592%)
    // perSecondRate = 1 + (0.07592/31557600), factor = perSecondRate^2592000
    // Expected 30-day growth rate = factor - 1 ≈ 0.00625521141
    // Expected credit growth = creditBefore * 0.00625950922 ≈ 346.58 MOET
    let expectedCreditGrowthRate: UFix64 = 0.0062552
    let expectedCreditGrowth: UFix64 = 346.58
    let tolerance: UFix64 = 0.0001

    let rateDiff = creditGrowthRate > expectedCreditGrowthRate
        ? creditGrowthRate - expectedCreditGrowthRate
        : expectedCreditGrowthRate - creditGrowthRate
    let growthDiff = creditGrowth > expectedCreditGrowth
        ? creditGrowth - expectedCreditGrowth
        : expectedCreditGrowth - creditGrowth

    log("Credit growth: \(creditGrowth.toString())")
    log("Expected credit growth: \(expectedCreditGrowth.toString())")
    log("Growth difference: \(growthDiff.toString())")
    log("Credit growth rate (30 days): \(creditGrowthRate.toString())")
    log("Expected credit growth rate: \(expectedCreditGrowthRate.toString())")
    log("Rate difference: \(rateDiff.toString())")

    Test.assert(
        growthDiff <= 0.01,
        message: "Credit growth should be ~346.58. Actual: \(creditGrowth)"
    )

    Test.assert(
        rateDiff <= tolerance,
        message: "Credit growth rate should be ~0.0062552. Actual: \(creditGrowthRate)"
    )

    log("=== TEST PASSED ===")
    log("Credit rate correctly responds to curve changes")
}
