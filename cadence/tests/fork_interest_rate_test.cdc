#test_fork(network: "mainnet-fork", height: 142528994)

import Test
import BlockchainHelpers

import "FlowToken"
import "FungibleToken"
import "MOET"
import "FlowALPEvents"

import "test_helpers.cdc"

access(all) let MAINNET_PROTOCOL_ACCOUNT = Test.getAccount(MAINNET_PROTOCOL_ACCOUNT_ADDRESS)
access(all) let MAINNET_USDF_HOLDER = Test.getAccount(MAINNET_USDF_HOLDER_ADDRESS)
access(all) let MAINNET_WETH_HOLDER = Test.getAccount(MAINNET_WETH_HOLDER_ADDRESS)
access(all) let MAINNET_WBTC_HOLDER = Test.getAccount(MAINNET_WBTC_HOLDER_ADDRESS)
access(all) let MAINNET_FLOW_HOLDER = Test.getAccount(MAINNET_FLOW_HOLDER_ADDRESS)

access(all) var snapshot: UInt64 = 0

// KinkCurve parameters (Aave v3 Volatile One)
access(all) let flowOptimalUtilization: UFix128 = 0.45  // 45% kink point
access(all) let flowBaseRate: UFix128 = 0.0             // 0% base rate
access(all) let flowSlope1: UFix128 = 0.04              // 4% slope below kink
access(all) let flowSlope2: UFix128 = 3.0               // 300% slope above kink

// Fixed rate for MOET
access(all) let moetFixedRate: UFix128 = 0.04

access(all)
fun safeReset() {
    let cur = getCurrentBlockHeight()
    if cur > snapshot {
        Test.reset(to: snapshot)
    }
}

access(all)
fun setup() {
    deployContracts()

    createAndStorePool(signer: MAINNET_PROTOCOL_ACCOUNT, defaultTokenIdentifier: MAINNET_MOET_TOKEN_ID, beFailed: false)
    setMockOraclePrice(signer: MAINNET_PROTOCOL_ACCOUNT, forTokenIdentifier: MAINNET_FLOW_TOKEN_ID, price: 1.0)

    addSupportedTokenKinkCurve(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_FLOW_TOKEN_ID,
        collateralFactor: 0.8,
        borrowFactor: 0.9,
        optimalUtilization: flowOptimalUtilization,
        baseRate: flowBaseRate,
        slope1: flowSlope1,
        slope2: flowSlope2,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // set MOET to use a FixedRateInterestCurve at 4% APY.
    setInterestCurveFixed(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_MOET_TOKEN_ID,
        yearlyRate: moetFixedRate
    )

    let res = setInsuranceSwapper(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        swapperInTypeIdentifier: MAINNET_FLOW_TOKEN_ID,
        swapperOutTypeIdentifier: MAINNET_MOET_TOKEN_ID,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    let setInsRes = setInsuranceRate(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_FLOW_TOKEN_ID,
        insuranceRate: 0.001,
    )
    Test.expect(setInsRes, Test.beSucceeded())

    snapshot = getCurrentBlockHeight()
}

// =============================================================================
/// Verifies protocol behavior when extreme utilization (nearly all liquidity borrowed)
// =============================================================================
access(all)
fun test_extreme_utilization() {
    safeReset()

    setInterestCurveKink(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_FLOW_TOKEN_ID,
        optimalUtilization: flowOptimalUtilization,
        baseRate: flowBaseRate,
        slope1: flowSlope1,
        slope2: flowSlope2
    )

    // create Flow LP with 2000 FLOW
    let FLOWAmount = 2000.0

    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: MAINNET_FLOW_HOLDER, amount: FLOWAmount, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
    let lpDepositPid = getLastPositionId()

    // create borrower with MOET collateral
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: borrower.address, amount: 10_000.0, beFailed: false)

    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: borrower, amount: 10_000.0, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, pushToDrawDownSink: false)

    let borrowerPid = getLastPositionId()
    // borrow 1800 FLOW (90% of 2000 FLOW credit)
    borrowFromPosition(
        signer: borrower,
        positionId: borrowerPid,
        tokenTypeIdentifier: MAINNET_FLOW_TOKEN_ID,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        amount: 1800.0,
        beFailed: false
    )

    // Pool state:
    //   FLOW credit = 2000
    //   FLOW debit  = 1800
    //
    // KinkInterestCurve:
    //   utilization = debitBalance / creditBalance
    //   utilization = 1800 / 2000 = 0.9 = 90% > 45% (above kink)
    //
    //   excessUtilization = (utilization - optimalUtilization) / (1 - optimalUtilization)
    //   excessUtilization = (0.9 - 0.45) / (1 - 0.45) = 0.45 / 0.55 = 0.81818181818...
    //
    //   rate = baseRate + slope1 + (slope2 * excessUtilization)
    //   rate = 0.0 + 0.04 + 3.0 * 0.81818181818 = 2.49454545454... (249.45% APY)

    // record initial state
    let detailsBefore = getPositionDetails(pid: borrowerPid, beFailed: false)
    let FLOWDebtBefore = getDebitBalanceForType(details: detailsBefore, vaultType: Type<@FlowToken.Vault>())

    // advance 30 days
    Test.moveTime(by: THIRTY_DAYS)
    Test.commitBlock()

    // perSecondRate = 1 + (yearlyRate / 31_557_600)
    // 30 days growth rate = perSecondRate ^ 2_592_000 - 1
    // FLOW debit 30 days growth rate = (1 + 2.49454545 / 31557600)^2592000 - 1 = 0.22739266 //0.22739266
    let expectedFLOWGrowthRate = 0.22739266

    // verify debt growth
    let detailsAfter = getPositionDetails(pid: borrowerPid, beFailed: false)
    let FLOWDebtAfter = getDebitBalanceForType(details: detailsAfter, vaultType: Type<@FlowToken.Vault>())
    Test.assert(FLOWDebtAfter > FLOWDebtBefore, message: "Debt should increase at above-kink utilization")

    let FLOWDebtGrowth = FLOWDebtAfter - FLOWDebtBefore
    let FLOWGrowthRate = FLOWDebtGrowth / FLOWDebtBefore

    // NOTE: TODO(Uliana): update to equalWithinVariance when PR https://github.com/onflow/FlowALP/pull/255 will be merged
    // We intentionally do not use `equalWithinVariance` with `defaultUFixVariance` here.
    // The default variance is designed for deterministic math, but insurance collection
    // depends on block timestamps, which can differ slightly between test runs.
    // A larger, time-aware tolerance is required.
    let tolerance = 0.00001
    var diff = expectedFLOWGrowthRate > FLOWGrowthRate 
        ? expectedFLOWGrowthRate - FLOWGrowthRate
        : FLOWGrowthRate - expectedFLOWGrowthRate
    Test.assert(diff < tolerance, message: "Expected FLOW debt growth rate to be \(expectedFLOWGrowthRate) but got \(FLOWGrowthRate)")
}

// =============================================================================
/// Verifies protocol borrow behavior when a lending pool has no available liquidity.
// =============================================================================
access(all)
fun test_zero_credit_balance() {
    safeReset()

    // setup borrower, create MOET position
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)

    let MOETAmount = 10_000.0
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: borrower.address, amount: MOETAmount, beFailed: false)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: borrower, amount: MOETAmount, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, pushToDrawDownSink: false)

    // no Flow LP is created — pool has zero FLOW liquidity

    // attempt to borrow FLOW (no reserves)
    let pid = getLastPositionId()

    let borrowRes = _executeTransaction(
        "./transactions/position-manager/borrow_from_position.cdc",
        [pid, MAINNET_FLOW_TOKEN_ID, FLOW_VAULT_STORAGE_PATH, 100.0],
        borrower
    )
    Test.expect(borrowRes, Test.beFailed())

    // FLOW interest rate calculation (KinkInterestCurve)
    //
    // totalCreditBalance = 0
    // totalDebitBalance = 0
    // baseRate = 0
    //
    // debitRate:
    //   debitRate = (if no debt, debitRate = base rate) = 0
    //
    // creditRate:
    //   creditRate = (debitIncome - protocolFeeAmount) / totalCreditBalance
    //   protocolFeeAmount = debitIncome * (insuranceRate + stabilityFeeRate)
    //   debitIncome = totalDebitBalance * debitRate
    //
    //   debitIncome = 0.0 * 0.0 = 0.0
    //   protocolFeeAmount = 0.0
    //   totalCreditBalance = 0.0 -> creditRate = 0.0

    // MOET interest rate calculation (FixedRateInterestCurve)
    //
    // totalCreditBalance = 10000
    // totalDebitBalance = 0
    //
    // debitRate:
    //   debitRate = yearlyRate = 0.04
    //
    // creditRate:
    //   creditRate = debitRate * (1.0 - protocolFeeRate)
    //   protocolFeeRate = insuranceRate + stabilityFeeRate
    //
    //   protocolFeeRate = 0.001 + 0.05 = 0.051
    //   creditRate = 0.04 * (1 - 0.051) = 0.03796 (3.796% APY)

    Test.moveTime(by: THIRTY_DAYS)
    Test.commitBlock()

    // perSecondRate = 1 + (yearlyRate / 31_557_600)
    // 30DaysGrowth = perSecondRate^THIRTY_DAYS - 1
    //
    // FLOW debt 30 days growth = (1 + 0/31_557_600)^2_592_000 - 1 = 0
    // MOET credit 30 days growth = (1 + 0.03796/31_557_600)^2_592_000 - 1 = 0.0003122730069
    let detailsAfterTime = getPositionDetails(pid: pid, beFailed: false)
    var moetCredit = getCreditBalanceForType(details: detailsAfterTime, vaultType: Type<@MOET.Vault>())
    Test.assert(moetCredit > 10000.0, message: "MOET credit should accrue interest")

    // add FLOW liquidity
    let FLOWAmount = 5000.0
    let flowLp = Test.createAccount()
    transferFungibleTokens(
        tokenIdentifier: MAINNET_FLOW_TOKEN_ID,
        from: MAINNET_FLOW_HOLDER,
        to: flowLp,
        amount: FLOWAmount
    )
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: flowLp, amount: FLOWAmount, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
    let lpPid = getLastPositionId()

    // borrow FLOW (Flow LP deposited 5000.0 FLOW, liquidity now available)
    borrowFromPosition(
        signer: borrower,
        positionId: pid,
        tokenTypeIdentifier: MAINNET_FLOW_TOKEN_ID,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        amount: 100.0,
        beFailed: false
    )

    let details = getPositionDetails(pid: pid, beFailed: false)
    let flowDebt = getDebitBalanceForType(details: details, vaultType: Type<@FlowToken.Vault>())
    Test.assertEqual(100.0, flowDebt)

    let lpDetails = getPositionDetails(pid: lpPid, beFailed: false)
    let flowCredit = getCreditBalanceForType(details: lpDetails, vaultType: Type<@FlowToken.Vault>())

    // FLOW interest rate calculation (KinkInterestCurve)
    //
    // totalCreditBalance = 5000
    // totalDebitBalance = 100
    //
    // debitRate:
    //   utilization = debitBalance / creditBalance
    //   utilization = 100 / 5000 = 0.02 < 0.45 (below kink)
    //
    //   debitRate = baseRate + (slope1 * utilization / optimalUtilization)
    //   debitRate = 0.0 + (0.04 * 0.02 / 0.45) = 0.00177777777 (0.177% APY)
    //
    // creditRate:
    //   creditRate = (debitIncome - protocolFeeAmount) / totalCreditBalance
    //   protocolFeeAmount = debitIncome * (insuranceRate + stabilityFeeRate)
    //   debitIncome = totalDebitBalance * debitRate
    //
    //   debitIncome = totalDebitBalance * debitRate = 100 * 0.00177777777 = 0.177777777
    //   protocolFeeRate = 0.001 + 0.05 = 0.051
    //   protocolFeeAmount = 0.177777777 * 0.051 = 0.00906666662
    //   creditRate = (0.177777777 - 0.00906666662) / 5000 = 0.00003374222 (0.003374% APY)

    // Advance 1 day to measure exact interest growth
    Test.moveTime(by: DAY)
    Test.commitBlock()

    // perSecondRate = 1 + (yearlyRate / 31_557_600)
    // daily growth rate = perSecondRate^86400 - 1
    // FLOW debt daily growth rate = (1 + 0.00177777777 / 31_557_600)^86400 - 1 = 0.00000486766
    let expectedFlowDebtDailyGrowth = 0.00000486

    let detailsAfter1Day = getPositionDetails(pid: pid, beFailed: false)
    let flowDebtAfter1Day = getDebitBalanceForType(details: detailsAfter1Day, vaultType: Type<@FlowToken.Vault>())
    let flowDebtDailyGrowth = (flowDebtAfter1Day - flowDebt) / flowDebt
    Test.assertEqual(expectedFlowDebtDailyGrowth, flowDebtDailyGrowth)

    // FLOW LP credit daily growth = (1 + 0.00003374222 / 31_557_600)^86400 - 1 = 0.00000009232
    let expectedFlowCreditDailyGrowth = 0.00000009
    let lpDetailsAfter1Day = getPositionDetails(pid: lpPid, beFailed: false)
    let flowCreditAfter1Day = getCreditBalanceForType(details: lpDetailsAfter1Day, vaultType: Type<@FlowToken.Vault>())
    let flowCreditDailyGrowth = (flowCreditAfter1Day - flowCredit) / flowCredit
    Test.assertEqual(expectedFlowCreditDailyGrowth, flowCreditDailyGrowth)
}

// =============================================================================
/// Verifies protocol behavior when a lending pool has liquidity but no borrowers.
// =============================================================================
access(all)
fun test_empty_pool() {
    safeReset()

    // create Flow LP only — no borrowers
    let flowLp = Test.createAccount()
    let FLOWAmount = 10000.0
    transferFungibleTokens(tokenIdentifier: MAINNET_FLOW_TOKEN_ID, from: MAINNET_FLOW_HOLDER, to: flowLp, amount: FLOWAmount)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: flowLp, amount: FLOWAmount, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    let lpPid = getLastPositionId()

    // record initial credit
    let detailsBefore = getPositionDetails(pid: lpPid, beFailed: false)
    let FLOWCreditBefore = getCreditBalanceForType(details: detailsBefore, vaultType: Type<@FlowToken.Vault>())

    // advance 30 days with zero borrowing
    Test.moveTime(by: THIRTY_DAYS)
    Test.commitBlock()

    // FLOW rate calculation (KinkInterestCurve)
    //   baseRate:0 
    //   debitBalance:0
    //
    // debitRate = (if no debt, debitRate = base rate) = 0
    // creditRate = 0 (debitIncome = 0)
    let detailsAfterNoDebit = getPositionDetails(pid: lpPid, beFailed: false)
    let FLOWCreditAfterNoDebit = getCreditBalanceForType(details: detailsAfterNoDebit, vaultType: Type<@FlowToken.Vault>())
    Test.assertEqual(FLOWCreditBefore, FLOWCreditAfterNoDebit)

    // create a borrower to trigger utilization
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: borrower.address, amount: 10_000.0, beFailed: false)

    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: borrower, amount: 10_000.0, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, pushToDrawDownSink: false)

    let borrowerPid= getLastPositionId()
    borrowFromPosition(
        signer: borrower,
        positionId: borrowerPid,
        tokenTypeIdentifier: MAINNET_FLOW_TOKEN_ID,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        amount: 2_000.0,
        beFailed: false
    )

    // advance another 30 days
    Test.moveTime(by: THIRTY_DAYS)
    Test.commitBlock()

    // KinkCurve
    // utilization = debitBalance / creditBalance
    //   FLOW: 2000 / 10000 = 0.2 < 0.45 (below kink)
    //
    // debitRate = baseRate + (slope1 * utilization / optimalUtilization)
    //   FLOW: debitRate = 0 + 0.04 * (0.2 / 0.45) = 0.01777777777 (1.777% APY)
    //
    // creditRate:
    //   creditRate = (debitIncome - protocolFeeAmount) / totalCreditBalance
    //   protocolFeeAmount = debitIncome * (insuranceRate + stabilityFeeRate)
    //   debitIncome = totalDebitBalance * debitRate
    //
    //   debitIncome = 2000 * 0.01777777777 = 35.55555554
    //   protocolFeeAmount = 35.55555554 * (0.001 + 0.05) = 1.81333333254
    //   creditRate = (35.55555554 - 1.81333333254) / 10000 = 0.00337422222 (0.337% APY)

    let detailsAfterDebit = getPositionDetails(pid: lpPid, beFailed: false)
    let FLOWCreditAfterDebit = getCreditBalanceForType(details: detailsAfterDebit, vaultType: Type<@FlowToken.Vault>())

    let FLOWCreditGrowth = FLOWCreditAfterDebit - FLOWCreditAfterNoDebit
    let FLOWCreditGrowthRate = FLOWCreditGrowth / FLOWCreditAfterNoDebit

    // perSecondRate = 1 + (yearlyRate / 31_557_600)
    // 30 Days Growth = perSecondRate^THIRTY_DAYS - 1
    // FLOW credit 30 days growth = (1 + 0.00337422222 / 31_557_600)^2_592_000 - 1 = 0.00027718
    let expectedFLOWCreditGrowthRate = 0.00027718
    Test.assertEqual(expectedFLOWCreditGrowthRate, FLOWCreditGrowthRate)
}

// =============================================================================
/// Verifies correct interest rate behavior at the utilization kink point.
// =============================================================================
access(all)
fun test_kink_point_transition() {
    safeReset()

    setInterestCurveKink(
        signer: MAINNET_PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MAINNET_FLOW_TOKEN_ID,
        optimalUtilization: flowOptimalUtilization,
        baseRate: flowBaseRate,
        slope1: flowSlope1,
        slope2: flowSlope2
    )

    // create LP with 10000 FLOW
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: MAINNET_FLOW_HOLDER, amount: 10000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    // create borrower with large MOET collateral
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: borrower.address, amount: 100_000.0, beFailed: false)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: borrower, amount: 100_000.0, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, pushToDrawDownSink: false)

    let borrowerPid = getLastPositionId()

    // KinkCurve
    // To achieve exactly 45% utilization:
    //   utilization = debit / credit
    //   0.45 = debit / 10000
    //   debit = 10000 * 0.45 = 4500
    borrowFromPosition(
        signer: borrower,
        positionId: borrowerPid,
        tokenTypeIdentifier: MAINNET_FLOW_TOKEN_ID,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        amount: 4500.0,
        beFailed: false
    )

    // KinkCurve
    // utilization = debitBalance / creditBalance
    //   FLOW: 4500 / 10000 = 0.45 <= 0.45 (exactly at kink)
    //
    // debitRate = baseRate + (slope1 * utilization / optimalUtilization)
    //   FLOW: debitRate = 0.0 + (0.04 * 0.45 / 0.45) = 0.04 (4% APY)

    // record state at kink point
    let detailsAtKink = getPositionDetails(pid: borrowerPid, beFailed: false)
    let debtAtKink = getDebitBalanceForType(details: detailsAtKink, vaultType: Type<@FlowToken.Vault>())

    // advance 1 year and verify rate matches 4% APY
    Test.moveTime(by: ONE_YEAR)
    Test.commitBlock()

    let detailsAfterYear = getPositionDetails(pid: borrowerPid, beFailed: false)
    let debtAfterYear = getDebitBalanceForType(details: detailsAfterYear, vaultType: Type<@FlowToken.Vault>())
    let yearlyGrowthAtKink = (debtAfterYear - debtAtKink) / debtAtKink

    // perSecondRate = 1 + (yearlyRate / 31_557_600)
    // yearly debt growth = perSecondRate^ONE_YEAR - 1
    // FLOW debit yearly growth = (1 + 0.04 / 31_557_600)^31_557_600 - 1 = 0.04081077417 (4.08%)
    let expectedYearlyGrowthAtKink = 0.04081077
    Test.assertEqual(expectedYearlyGrowthAtKink, yearlyGrowthAtKink)
}

// =============================================================================
/// Verifies interest accrual over long time periods
// =============================================================================
access(all)
fun test_long_time_period_accrual() {
    safeReset()

    // create LP with 10000 FLOW
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: MAINNET_FLOW_HOLDER, amount: 10000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
    let lpPid = getLastPositionId()

    // create borrower
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: borrower.address, amount: 100_000.0, beFailed: false)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: borrower, amount: 100_000.0, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, pushToDrawDownSink: false)

    let borrowerPid = getLastPositionId()

    // borrow 2000 FLOW
    borrowFromPosition(
        signer: borrower,
        positionId: borrowerPid,
        tokenTypeIdentifier: MAINNET_FLOW_TOKEN_ID,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        amount: 2000.0,
        beFailed: false
    )

    // Borrower FLOW rate calculation (KinkInterestCurve)
    // KinkCurve
    // utilization = debitBalance / creditBalance
    //   FLOW: 2000 / 10000 = 0.2 < 0.45 (below kink)
    //
    // debitRate = baseRate + (slope1 * utilization / optimalUtilization)
    //   FLOW: debitRate = 0 + 0.04 * (0.2 / 0.45) = 0.01777777777 (1.77% APY)

    let detailsBefore = getPositionDetails(pid: borrowerPid, beFailed: false)
    let FLOWDebtBefore = getDebitBalanceForType(details: detailsBefore, vaultType: Type<@FlowToken.Vault>())

    let FLOWCreditBefore = getCreditBalanceForType(details: getPositionDetails(pid: lpPid, beFailed: false), vaultType: Type<@FlowToken.Vault>())

    // 1 full year
    Test.moveTime(by: ONE_YEAR)
    Test.commitBlock()

    let detailsAfter1Year = getPositionDetails(pid: borrowerPid, beFailed: false)
    let FLOWDebtAfter1Year = getDebitBalanceForType(details: detailsAfter1Year, vaultType: Type<@FlowToken.Vault>())
    let FLOWGrowthRate1Year = (FLOWDebtAfter1Year - FLOWDebtBefore) / FLOWDebtBefore

    // perSecondRate = 1 + (yearlyRate / 31_557_600)
    // yearly debt growth = perSecondRate^ONE_YEAR - 1
    // FLOW debit yearly growth = (1 + 0.017777778 / 31_557_600)^31_557_600 - 1 = 0.01793674
    let expectedFLOWDebtYearlyGrowth = 0.01793674
    Test.assertEqual(expectedFLOWDebtYearlyGrowth, FLOWGrowthRate1Year)

    // LP credit should also have grown
    let creditAfter1Year = getCreditBalanceForType(
        details: getPositionDetails(pid: lpPid, beFailed: false),
        vaultType: Type<@FlowToken.Vault>()
    )
    Test.assert(creditAfter1Year > FLOWCreditBefore, message: "credit should grow over 1 year")

    // advance 10 more years
    Test.moveTime(by: 10.0 * ONE_YEAR)
    Test.commitBlock()

    let detailsAfter10Years = getPositionDetails(pid: borrowerPid, beFailed: false)
    let FLOWDebtAfter10Years = getDebitBalanceForType(details: detailsAfter10Years, vaultType: Type<@FlowToken.Vault>())
    let FLOWTotalGrowthRate = (FLOWDebtAfter10Years - FLOWDebtBefore) / FLOWDebtBefore

    // perSecondRate = 1 + (yearlyRate / 31_557_600)
    // 11-year debt growth = perSecondRate^(31_557_600 * 11) - 1
    // FLOW debit 11-year growth = (1 + 0.017777778 / 31_557_600)^(31_557_600*11) - 1 = 0.21598635
    let expectedFLOWDebt10YearsGrowth = 0.21598635
    Test.assertEqual(expectedFLOWDebt10YearsGrowth, FLOWTotalGrowthRate)
}

// =============================================================================
/// Verifies that interest accrues correctly after large time jumps
// =============================================================================
access(all)
fun test_time_jump_scenarios() {
    safeReset()

    // set up LP and borrower
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: MAINNET_FLOW_HOLDER, amount: 10000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: borrower.address, amount: 50_000.0, beFailed: false)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: borrower, amount: 50_000.0, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, pushToDrawDownSink: false)

    let borrowerPid = getLastPositionId()

    // borrow 5000 FLOW
    borrowFromPosition(
        signer: borrower,
        positionId: borrowerPid,
        tokenTypeIdentifier: MAINNET_FLOW_TOKEN_ID,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        amount: 5000.0,
        beFailed: false
    )

    // record state before the 1-day gap
    let detailsBefore = getPositionDetails(pid: borrowerPid, beFailed: false)
    let FLOWDebtBefore = getDebitBalanceForType(details: detailsBefore, vaultType: Type<@FlowToken.Vault>())

    // Borrower FLOW rate calculation (KinkInterestCurve)
    // utilization = debitBalance / creditBalance
    //   FLOW: 5000 / 10000 = 0.5 > 0.45 (above kink)
    //
    // excessUtilization = (utilization - optimalUtilization) / (1 - optimalUtilization)
    //   = (0.5 - 0.45) / (1 - 0.45) = 0.05 / 0.55 = 0.09090909090909...
    //
    // debitRate = baseRate + slope1 + (slope2 * excessUtilization)
    //   FLOW: debitRate = 0 + 0.04 + 3.0 * 0.09090909 = 0.3127272727... (31.27% APY)
    let expectedFlowDebitRate: UFix128 = 0.31272727

    // 1-day blockchain halt
    Test.moveTime(by: DAY)
    Test.commitBlock()

    // first transaction after restart — interest accrual for full gap
    let detailsAfter1Day = getPositionDetails(pid: borrowerPid, beFailed: false)
    let FLOWDebtAfter1Day = getDebitBalanceForType(details: detailsAfter1Day, vaultType: Type<@FlowToken.Vault>())

    Test.assert(FLOWDebtAfter1Day > FLOWDebtBefore, message: "Debt should increase after 1-day gap")
    let FLOWDebtDailyGrowth = (FLOWDebtAfter1Day - FLOWDebtBefore) / FLOWDebtBefore

    // perSecondRate = 1 + (yearlyRate / 31_557_600)
    // dailyGrowth = perSecondRate^86400 - 1
    // FLOW debit daily growth = (1 + 0.31272727 / 31557600)^86400 - 1 = 0.00085660
    let expectedFLOWDebtDailyGrowth = 0.00085660
    Test.assert(equalWithinVariance(expectedFLOWDebtDailyGrowth, FLOWDebtDailyGrowth, DEFAULT_UFIX_VARIANCE),
        message: "Expected FLOW debt growth rate to be ~\(expectedFLOWDebtDailyGrowth), but got \(FLOWDebtDailyGrowth)")

    // test longer period (7 days) to verify no overflow in calculation
    let detailsBefore7Day = getPositionDetails(pid: borrowerPid, beFailed: false)
    let FlowDebtBefore7Day = getDebitBalanceForType(details: detailsBefore7Day, vaultType: Type<@FlowToken.Vault>())

    // 7 days blockchain halt
    Test.moveTime(by: 7.0 * DAY)
    Test.commitBlock()

    let detailsAfter7Day = getPositionDetails(pid: borrowerPid, beFailed: false)
    let FLOWDebtAfter7Day = getDebitBalanceForType(details: detailsAfter7Day, vaultType: Type<@FlowToken.Vault>())
    Test.assert(FLOWDebtAfter7Day > FlowDebtBefore7Day, message: "FLOW Debt should increase after 7-day gap")

    let FLOWDebtWeeklyGrowth = (FLOWDebtAfter7Day - FlowDebtBefore7Day) / FlowDebtBefore7Day
    // weeklyGrowth = perSecondRate^604800 - 1
    // FLOW debit weekly growth = (1 + 0.31272727272 / 31_557_600)^604800 - 1 = 0.00601143
    let expectedFLOWDebtWeeklyGrowth = 0.00601143
    Test.assert(equalWithinVariance(expectedFLOWDebtWeeklyGrowth, FLOWDebtWeeklyGrowth, DEFAULT_UFIX_VARIANCE),
        message: "Expected FLOW debt growth rate to be ~\(expectedFLOWDebtWeeklyGrowth), but got \(FLOWDebtWeeklyGrowth)")
}