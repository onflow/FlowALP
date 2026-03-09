#test_fork(network: "mainnet", height: 142528994)

import Test
import BlockchainHelpers

import "FlowToken"
import "FungibleToken"
import "MOET"
import "FlowALPv0"

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
    var err = Test.deployContract(
        name: "DeFiActionsUtils",
        path: "../../FlowActions/cadence/contracts/utils/DeFiActionsUtils.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    err = Test.deployContract(
        name: "FlowALPMath",
        path: "../lib/FlowALPMath.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    err = Test.deployContract(
        name: "DeFiActions",
        path: "../../FlowActions/cadence/contracts/interfaces/DeFiActions.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "MockOracle",
        path: "../contracts/mocks/MockOracle.cdc",
        arguments: [MAINNET_MOET_TOKEN_ID]
    )
    Test.expect(err, Test.beNil())

    // Deploy FungibleTokenConnectors
    err = Test.deployContract(
        name: "FungibleTokenConnectors",
        path: "../../FlowActions/cadence/contracts/connectors/FungibleTokenConnectors.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "MockDexSwapper",
        path: "../contracts/mocks/MockDexSwapper.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

     err = Test.deployContract(
        name: "FlowALPv0",
        path: "../contracts/FlowALPv0.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

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
/// Verifies the scenario when there is no liquidity to borrow.
/// Any attempt to borrow should fail because the pool has no reserves for that token.
/// When new deposit goes, user could borrow.
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
    let openEvents = Test.eventsOfType(Type<FlowALPv0.Opened>())
    let pid = (openEvents[openEvents.length - 1] as! FlowALPv0.Opened).pid

    let borrowRes = _executeTransaction(
        "./transactions/position-manager/borrow_from_position.cdc",
        [pid, MAINNET_FLOW_TOKEN_ID, FLOW_VAULT_STORAGE_PATH, 100.0],
        borrower
    )
    Test.expect(borrowRes, Test.beFailed())

    // FLOW interest rate calculation 
    //
    // totalCreditBalance = 0
    // totalDebitBalance = 0
    // baseRate = 0
    //
    // KinkInterestCurve:
    // debitRate:   
    //   debitRate = (if no debt, debitRate = base rate) = 0
    //
    // creditRate:
    //     creditRate = (debitIncome - protocolFeeAmount) / totalCreditBalance
    //     protocolFeeAmount = debitIncome * (insuranceRate + stabilityFeeRate)
    //     debitIncome = totalDebitBalance * debitRate
    //
    //     debitIncome = 0.0 * 0.0 = 0.0
    //     protocolFeeAmount = 0.0
    //     totalCreditBalance = 0.0 -> creditRate = 0.0

    // MOET interest rate calculation (FixedRateInterestCurve)
    //
    // totalCreditBalance = 10000
    // totalDebitBalance = 0
    //
    // debitRate:   
    //   debitRate = yearlyRate = 0.04
    //
    // creditRate:
    //     creditRate = debitRate * (1.0 - protocolFeeRate)
    //     protocolFeeRate = insuranceRate + stabilityFeeRate
    //
    //     protocolFeeRate = 0.001 * 0.05 = 0.051
    //     creditRate = 0.04 * (1 - 0.051) = 0.03796 (3.796 % APY)
    //
    
    Test.moveTime(by: THIRTY_DAYS)
    Test.commitBlock()

    // perSecondRate = 1 + (yearlyRate / 31_557_600)
    // 30DaysGrowth = perSecondRate^THIRTY_DAYS - 1
    //
    // FLOW debt 30 days growth = (1 + 0/31_557_600)^2_592_000 - 1 = 0
    // MOET credit 30 days growth = (1 + 0.03796/31_557_600)^2_592_000 - 1 = 0.0003122730069
    let detailsAfterTime = getPositionDetails(pid: pid, beFailed: false)
    let moetCredit = getCreditBalanceForType(details: detailsAfterTime, vaultType: Type<@MOET.Vault>())
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

    // FLOW interest rate calculation (KinkInterestCurve)
    //
    // totalCreditBalance = 5000
    // totalDebitBalance = 100
    //
    // debitRate:  
    //   utilization = debitBalance / (creditBalance + debitBalance) 
    //   utilization = 100 / (5000 + 100) = 100 / 5100 = 0.01960784 < 0.45 (below kink)
    //
    //   debitRate = baseRate + (slope1 * utilization / optimalUtilization)
    //   debitRate = 0.0 + (0.04 * 0.01960784 / 0.45) = 0.00174291 (0.174% APY)
    //
    // creditRate:
    //     creditRate = (debitIncome - protocolFeeAmount) / totalCreditBalance
    //     protocolFeeAmount = debitIncome * (insuranceRate + stabilityFeeRate)
    //     debitIncome = totalDebitBalance * debitRate
    //
    //     debitIncome = 0.0 * 0.0 = 0.0
    //     protocolFeeAmount = 0.0
    //     totalCreditBalance = 0.0 -> creditRate = 0.0

    // Advance 1 day to measure exact interest growth
    Test.moveTime(by: DAY)
    Test.commitBlock()
    // perSecondRate = 1 + (yearlyRate / 31_557_600)
    // daily growth rate = perSecondRate^86400 - 1
    // FLOW debt daily growth rate = (1 + 0.00174291 / 31_557_600)^86400 - 1 = 0.00000477
    let expectedFlowDebtDailyGrowth = 0.00000477

    let detailsAfter1Day = getPositionDetails(pid: pid, beFailed: false)
    let flowDebtAfter1Day = getDebitBalanceForType(details: detailsAfter1Day, vaultType: Type<@FlowToken.Vault>())
    let flowDebtDailyGrowth = (flowDebtAfter1Day - flowDebt) / flowDebt
    Test.assertEqual(expectedFlowDebtDailyGrowth, flowDebtDailyGrowth)
}

// =============================================================================
/// Verifies protocol behavior when a lending pool has liquidity but no borrows.
// =============================================================================
access(all)
fun test_empty_pool() {
    safeReset()

    // create Flow LP only — no borrowers
    let flowLp = Test.createAccount()
    let FLOWAmount = 10000.0
    transferFungibleTokens(tokenIdentifier: MAINNET_FLOW_TOKEN_ID, from: MAINNET_FLOW_HOLDER, to: flowLp, amount: FLOWAmount)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: flowLp, amount: FLOWAmount, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    let openEvents = Test.eventsOfType(Type<FlowALPv0.Opened>())
    let lpPid = (openEvents[openEvents.length - 1] as! FlowALPv0.Opened).pid

    // record initial credit
    let detailsBefore = getPositionDetails(pid: lpPid, beFailed: false)
    let FLOWcreditBefore = getCreditBalanceForType(details: detailsBefore, vaultType: Type<@FlowToken.Vault>())

    // advance 30 days with zero borrowing
    Test.moveTime(by: THIRTY_DAYS)
    Test.commitBlock()

    // calculate FLOW rates
    // KinkCurve:
    //      baseRate:0 
    //      debitBalance:0
    // debitRate: debitRate = baseRate = 0 (debitBalance = 0) 
    // creditRate: creditRate = 0 (debitIncome = 0)
    let detailsAfterNoDebit = getPositionDetails(pid: lpPid, beFailed: false)
    let FLOWCreditAfterNoDebit = getCreditBalanceForType(details: detailsAfterNoDebit, vaultType: Type<@FlowToken.Vault>())
    Test.assertEqual(FLOWcreditBefore, FLOWCreditAfterNoDebit)

    // create a borrower to trigger utilization
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: borrower.address, amount: 10_000.0, beFailed: false)

    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: borrower, amount: 10_000.0, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, pushToDrawDownSink: false)

    let borrowerPid: UInt64 = 1
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
    // utilization = debitBalance / (creditBalance + debitBalance)
    //     FLOW: 2000 / (10000 + 2000) =  0.16666666666 < 0.45 (below kink)
    //
    // debitRate = baseRate + (slope1 * utilization / optimalUtilization)
    //     FLOW: debitRate = 0 + 0.04 * (0.16666666666 / 0.45) = 0.01481481481 (1.48% APY)
    //
    // creditRate:
    //     creditRate = (debitIncome - protocolFeeAmount) / totalCreditBalance
    //     protocolFeeAmount = debitIncome * (insuranceRate + stabilityFeeRate)
    //     debitIncome = totalDebitBalance * debitRate
    //     
    //     debitIncome = 2000 * 0.01481481481 = 29.62962962
    //     protocolFeeAmount = 29.62962962 * (0.001 + 0.05) =  1.51111111062
    //     FLOW: creditRate = (29.62962962 - 1.51111111062) / 10000 =  0.00281185185 (0.28% APY)

    let detailsAfterDebit = getPositionDetails(pid: lpPid, beFailed: false)
    let FLOWCreditAfterDebit = getCreditBalanceForType(details: detailsAfterDebit, vaultType: Type<@FlowToken.Vault>())

    let FLOWCreditGrowth = FLOWCreditAfterDebit - FLOWCreditAfterNoDebit
    let FLOWCreditGrowthRate = FLOWCreditGrowth / FLOWCreditAfterNoDebit

    // perSecondRate = 1 + (yearlyRate / 31_557_600)
    // 30 Days Growth = perSecondRate^THIRTY_DAYS - 1
    // FLOW credit 30 days growth = (1 + 0.00281185/31_557_600)^2_592_000 - 1 = 0.0002309792
    let expectedFLOWCreditGrowthRate = 0.00023097
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
    var openEvents = Test.eventsOfType(Type<FlowALPv0.Opened>())
    let lpPid = (openEvents[openEvents.length - 1] as! FlowALPv0.Opened).pid

    // create borrower with large MOET collateral
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: borrower.address, amount: 100_000.0, beFailed: false)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: borrower, amount: 100_000.0, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, pushToDrawDownSink: false)
    
    openEvents = Test.eventsOfType(Type<FlowALPv0.Opened>())
    let borrowerPid = (openEvents[openEvents.length - 1] as! FlowALPv0.Opened).pid

    // KinkCurve
    // To achieve exactly 45% utilization:
    //   utilization = debit / (credit + debit)
    //   0.45 = debit / (credit + debit)
    //
    //   0.45 * credit = 0.55 * debit
    //   credit = (0.55 / 0.45) * debit = (11/9) * debit
    //
    //   credit = 10000
    //   debit = 10000 * 9/11 = 8181.818181
    //
    // utilization = 8181.818181 / (10000 + 8181.818181) = 0.45
    borrowFromPosition(
        signer: borrower,
        positionId: borrowerPid,
        tokenTypeIdentifier: MAINNET_FLOW_TOKEN_ID,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        amount: 8181.818181,
        beFailed: false
    )

    // KinkCurve
    // utilization = debitBalance / (creditBalance + debitBalance)
    //     FLOW: 0.45 <= 0.45 (below kink)
    //
    // debit rate = baseRate + (slope1 * utilization / optimalUtilization)
    //     FLOW: debitRate = 0.0 + (0.04 * 0.45 / 0.45) = 0.04 (4% APY)

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
/// Verifies interest accrual over long time periods.
/// Advances blockchain time by 1 year and then by 10 additional years,
/// ensuring the borrower’s debt grows according to the expected
/// compounded interest rate without overflow or precision issues.
// =============================================================================
access(all)
fun test_long_time_period_accrual() {
    safeReset()

    // create LP with 10000 FLOW
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: MAINNET_FLOW_HOLDER, amount: 10000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
    
    var openEvents = Test.eventsOfType(Type<FlowALPv0.Opened>())
    let lpPid = (openEvents[openEvents.length - 1] as! FlowALPv0.Opened).pid

    // create borrower
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: borrower.address, amount: 100_000.0, beFailed: false)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: borrower, amount: 100_000.0, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, pushToDrawDownSink: false)
    
    openEvents = Test.eventsOfType(Type<FlowALPv0.Opened>())
    let borrowerPid = (openEvents[openEvents.length - 1] as! FlowALPv0.Opened).pid

    // borrow 2000 FLOW
    borrowFromPosition(
        signer: borrower,
        positionId: borrowerPid,
        tokenTypeIdentifier: MAINNET_FLOW_TOKEN_ID,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        amount: 2000.0,
        beFailed: false
    )

    // Borrower (MOET collateral, FLOW debt):
    // KinkCurve
    // utilization = debitBalance / (creditBalance + debitBalance)
    //     FLOW: 2000 / (10000 + 2000) =  0.16666666666 < 0.45 (below kink)
    //
    // debit rate = baseRate + (slope1 * utilization / optimalUtilization)
    //     FLOW: debitRate = 0 + 0.04 * (0.16666666666 / 0.45) = 0.01481481481 (1.48% APY)
    let expectedFLOWDebtRate = 0.01481481

    let detailsBefore = getPositionDetails(pid: borrowerPid, beFailed: false)
    let debtBefore = getDebitBalanceForType(details: detailsBefore, vaultType: Type<@FlowToken.Vault>())

    let creditBefore = getCreditBalanceForType(details: getPositionDetails(pid: lpPid, beFailed: false),
        vaultType: Type<@FlowToken.Vault>()
    )

    // 1 full year
    Test.moveTime(by: ONE_YEAR)
    Test.commitBlock()

    let detailsAfter1Year = getPositionDetails(pid: borrowerPid, beFailed: false)
    let FLOWDebtAfter1Year = getDebitBalanceForType(details: detailsAfter1Year, vaultType: Type<@FlowToken.Vault>())
    let FLOWGrowthRate1Year = (FLOWDebtAfter1Year - debtBefore) / debtBefore

    // perSecondRate = 1 + (yearlyRate / 31_557_600)
    // yearly debt growth = perSecondRate^ONE_YEAR - 1 
    // FLOW debit yearly growth = (1 + 0.01481481481 / 31_557_600)^31_557_600 - 1 = 0.01492509772
    let expectedFLOWDebtYearlyGrowth = 0.01492509 // TODO(Uliana) + add credit rate growth
    Test.assertEqual(expectedFLOWDebtYearlyGrowth, FLOWGrowthRate1Year)

    // LP credit should also have grown
    let creditAfter1Year = getCreditBalanceForType(
        details: getPositionDetails(pid: lpPid, beFailed: false),
        vaultType: Type<@FlowToken.Vault>()
    )
    Test.assert(creditAfter1Year > creditBefore, message: "credit should grow over 1 year")

    // advance 10 years
    Test.moveTime(by: 10.0 * ONE_YEAR)
    Test.commitBlock()

    let detailsAfter10Years = getPositionDetails(pid: borrowerPid, beFailed: false)
    let FLOWDebtAfter10Years = getDebitBalanceForType(details: detailsAfter10Years, vaultType: Type<@FlowToken.Vault>())
    let FLOWTotalGrowthRate = (FLOWDebtAfter10Years - debtBefore) / debtBefore

    // perSecondRate = 1 + (yearlyRate / 31_557_600)
    // 11-years debt growth = perSecondRate^(31_557_600*11) - 1 
    // FLOW debit 11-years growth = (1 + 0.01481481481 / 31_557_600)^(31_557_600*11) - 1 = 0.17699309112
    let expectedFLOWDebt10YearsGrowth = 0.17699309
    Test.assertEqual(expectedFLOWDebt10YearsGrowth, FLOWTotalGrowthRate)
}

// =============================================================================
/// Verifies that interest accrues correctly after large time jumps.
/// Simulates blockchain halts (1 day and 7 days) and ensures the borrower’s
/// debt increases according to the expected compounded interest rate.
// =============================================================================
access(all)
fun test_time_jump_scenarios() {
    safeReset()

    // set up LP and borrower
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: MAINNET_FLOW_HOLDER, amount: 10000.0, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)
    var openEvents = Test.eventsOfType(Type<FlowALPv0.Opened>())
    let lpPid = (openEvents[openEvents.length - 1] as! FlowALPv0.Opened).pid

    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    mintMoet(signer: MAINNET_PROTOCOL_ACCOUNT, to: borrower.address, amount: 50_000.0, beFailed: false)
    createPosition(admin: MAINNET_PROTOCOL_ACCOUNT, signer: borrower, amount: 50_000.0, vaultStoragePath: MAINNET_MOET_STORAGE_PATH, pushToDrawDownSink: false)
    
    openEvents = Test.eventsOfType(Type<FlowALPv0.Opened>())
    let borrowerPid = (openEvents[openEvents.length - 1] as! FlowALPv0.Opened).pid

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
    let healthBefore = detailsBefore.health

    // Borrower (MOET collateral, FLOW debt):
    // KinkCurve
    // utilization = debitBalance / (creditBalance + debitBalance)
    //     FLOW: 5000 / (10000 + 5000) = 0.3(3) < 0.45 (below kink)
    //
    // debit rate = baseRate + (slope1 * utilization / optimalUtilization)
    //     FLOW: debitRate = 0 + (0.04 * 0.3(3) / 0.45) = 0.0296296296296296 (2.96% APY)
    let expectedFlowDebitRate: UFix128 = 0.02962963

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
    // FLOW debit daily growth = (1 + 0.02962963 / 31_557_600)^86400 - 1 = 0.00008112479

    let expectedFLOWDebtDailyGrowth = 0.00008112
    Test.assertEqual(expectedFLOWDebtDailyGrowth, FLOWDebtDailyGrowth)

    // try oto test longer period (7 days) to verify no overflow in calculation 
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
    // FLOW debit weekly growth = (1 + 0.02962963/31_557_600)^604800 - 1 = 0.00056801
    let expectedFLOWDebtWeeklyGrowth = 0.00056801
    Test.assertEqual(expectedFLOWDebtWeeklyGrowth, FLOWDebtWeeklyGrowth)
}