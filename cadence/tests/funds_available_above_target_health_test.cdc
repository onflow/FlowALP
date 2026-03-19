import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "MOET"
import "FlowToken"
import "FlowALPv0"
import "FlowALPEvents"
import "FlowALPModels"

access(all) let userAccount = Test.createAccount()

access(all) let flowCollateralFactor = 0.8
access(all) let flowBorrowFactor = 1.0
access(all) let flowStartPrice = 1.0            // denominated in MOET
access(all) let positionFundingAmount = 100.0   // FLOW        
access(all) var positionID: UInt64 = 0

access(all) var snapshot: UInt64 = 0

/**

    REFERENCE MATHS
    ---------------
    NOTE: These methods do not yet account for true balance (i.e. deposited/withdrawn + interest)

    Effective Collateral Value (MOET)
        effectiveCollateralValue = collateralBalance * collateralPrice * collateralFactor
    Borrowable Value (MOET)
        borrowLimit = (effectiveCollateralValue / TARGET_HEALTH) * borrowFactor
        borrowLimit = collateralBalance * collateralPrice * collateralFactor / TARGET_HEALTH * borrowFactor
    Current Health
        borrowedValue = collateralBalance * collateralPrice * collateralFactor / TARGET_HEALTH * borrowFactor
        borrowedValue * TARGET_HEALTH = collateralBalance * collateralPrice * collateralFactor * borrowFactor
        health = collateralBalance * collateralPrice * collateralFactor * borrowFactor / borrowedValue
        health = effectiveCollateralValue * borrowFactor / borrowedValue

 */

access(all) let startCollateralValue = flowStartPrice * positionFundingAmount
access(all) let startEffectiveCollateralValue = startCollateralValue * flowCollateralFactor
access(all) let startBorrowLimitAtTarget = startEffectiveCollateralValue / TARGET_HEALTH

access(all)
fun setup() {

    log("----- SETTING UP funds_available_above_target_health_test.cdc -----")

    deployContracts()

    // price setup
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: flowStartPrice)

    // create the Pool & add FLOW as suppoorted token
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: flowCollateralFactor,
        borrowFactor: flowBorrowFactor,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // prep user's account
    setupMoetVault(userAccount, beFailed: false)
    mintFlow(to: userAccount, amount: positionFundingAmount)

    // Grant beta access to userAccount so they can create positions
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, userAccount)

    snapshot = getCurrentBlockHeight()

    log("----- funds_available_above_target_health_test.cdc SETUP COMPLETE -----")
}

access(all)
fun testFundsAvailableAboveTargetHealthAfterDepositingWithPushFromHealthy() {
    log("==============================")
    log("[TEST] Executing testFundsAvailableAboveTargetHealthAfterDepositingWithPushFromHealthy()")

    if snapshot < getCurrentBlockHeight() {
        Test.reset(to: snapshot)
    }

    let openRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [positionFundingAmount, FLOW_VAULT_STORAGE_PATH, true],
        userAccount
    )
    Test.expect(openRes, Test.beSucceeded())
    // assert expected starting point
    let balanceAfterBorrow = getBalance(address: userAccount.address, vaultPublicPath: MOET.VaultPublicPath)!
    let expectedBorrowAmount = (positionFundingAmount * flowCollateralFactor * flowStartPrice) / TARGET_HEALTH
    Test.assert(equalWithinVariance(expectedBorrowAmount, balanceAfterBorrow),
        message: "Expected MOET balance to be ~\(expectedBorrowAmount), but got \(balanceAfterBorrow)")

    let evts = Test.eventsOfType(Type<FlowALPEvents.Opened>())
    let openedEvt = evts[evts.length - 1] as! FlowALPEvents.Opened
    positionID = openedEvt.pid

    let positionDetails = getPositionDetails(pid: positionID, beFailed: false)
    let health = positionDetails.health
    // Find balances by direction rather than relying on array ordering
    var flowPositionBalance: FlowALPModels.PositionBalance? = nil
    var moetBalance: FlowALPModels.PositionBalance? = nil
    for b in positionDetails.balances {
        if b.direction == FlowALPModels.BalanceDirection.Credit {
            flowPositionBalance = b
        } else {
            moetBalance = b
        }
    }
    Test.assertEqual(positionFundingAmount, flowPositionBalance!.balance)

    Test.assert(equalWithinVariance(expectedBorrowAmount, moetBalance!.balance),
        message: "Expected borrow amount to be \(expectedBorrowAmount), but got \(moetBalance!.balance)")

    Test.assert(equalWithinVariance(INT_TARGET_HEALTH, health),
        message: "Expected health to be \(INT_TARGET_HEALTH), but got \(health)")

    log("[TEST] FLOW price set to \(flowStartPrice)")

    let amounts: [UFix64] = [0.0, 10.0, 100.0, 1_000.0, 10_000.0, 100_000.0, 1_000_000.0]
    let expectedExcess = 0.0 // none available above target from healthy state

    let internalSnapshot = getCurrentBlockHeight()
    for i, amount in amounts {
        runFundsAvailableAboveTargetHealthAfterDepositing(
            pid: positionID,
            existingBorrowed: expectedBorrowAmount,
            existingFLOWCollateral: positionFundingAmount,
            currentFLOWPrice: flowStartPrice,
            depositAmount: amount,
            withdrawIdentifier: MOET_TOKEN_IDENTIFIER,
            depositIdentifier: FLOW_TOKEN_IDENTIFIER
        )

        // minting to topUpSource Vault which should *not* affect calculation
        let mintToSource = amount < 100.0 ? 100.0 : amount * 10.0
        log("[TEST] Minting \(mintToSource) to position topUpSource and running again")
        mintMoet(signer: PROTOCOL_ACCOUNT, to: userAccount.address, amount: mintToSource, beFailed: false)

        runFundsAvailableAboveTargetHealthAfterDepositing(
            pid: positionID,
            existingBorrowed: expectedBorrowAmount,
            existingFLOWCollateral: positionFundingAmount,
            currentFLOWPrice: flowStartPrice,
            depositAmount: amount,
            withdrawIdentifier: MOET_TOKEN_IDENTIFIER,
            depositIdentifier: FLOW_TOKEN_IDENTIFIER
        )

        Test.reset(to: internalSnapshot)
    }

    log("==============================")
}

access(all)
fun testFundsAvailableAboveTargetHealthAfterDepositingWithoutPushFromHealthy() {
    log("==============================")
    log("[TEST] Executing testFundsAvailableAboveTargetHealthAfterDepositingWithoutPushFromHealthy()")

    if snapshot < getCurrentBlockHeight() {
        Test.reset(to: snapshot)
    }

    let openRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [positionFundingAmount, FLOW_VAULT_STORAGE_PATH, false],
        userAccount
    )
    Test.expect(openRes, Test.beSucceeded())

    // assert expected starting point
    let balanceAfterBorrow = getBalance(address: userAccount.address, vaultPublicPath: MOET.VaultPublicPath)!
    let expectedBorrowAmount = 0.0
    Test.assertEqual(expectedBorrowAmount, balanceAfterBorrow)

    let evts = Test.eventsOfType(Type<FlowALPEvents.Opened>())
    let openedEvt = evts[evts.length - 1] as! FlowALPEvents.Opened
    positionID = openedEvt.pid

    let positionDetails = getPositionDetails(pid: positionID, beFailed: false)
    let health = positionDetails.health
    let flowPositionBalance = positionDetails.balances[0]
    Test.assertEqual(positionFundingAmount, flowPositionBalance.balance)
    Test.assertEqual(FlowALPModels.BalanceDirection.Credit, flowPositionBalance.direction)

    Test.assertEqual(CEILING_HEALTH, health)

    log("[TEST] FLOW price set to \(flowStartPrice)")

    let amounts: [UFix64] = [0.0, 10.0, 100.0, 1_000.0, 10_000.0, 100_000.0, 1_000_000.0]
    var expectedExcess = 0.0 // none available above target from healthy state
    var expectedDeficit = ((positionFundingAmount * flowCollateralFactor) / TARGET_HEALTH * flowBorrowFactor) * flowStartPrice

    let internalSnapshot = getCurrentBlockHeight()
    for i, amount in amounts {
        runFundsAvailableAboveTargetHealthAfterDepositing(
            pid: positionID,
            existingBorrowed: expectedBorrowAmount,
            existingFLOWCollateral: positionFundingAmount,
            currentFLOWPrice: flowStartPrice,
            depositAmount: amount,
            withdrawIdentifier: MOET_TOKEN_IDENTIFIER,
            depositIdentifier: FLOW_TOKEN_IDENTIFIER
        )

        // minting to topUpSource Vault which should *not* affect calculation
        let mintToSource = amount < 100.0 ? 100.0 : amount * 10.0
        log("[TEST] Minting \(mintToSource) to position topUpSource and running again")
        mintMoet(signer: PROTOCOL_ACCOUNT, to: userAccount.address, amount: mintToSource, beFailed: false)

        runFundsAvailableAboveTargetHealthAfterDepositing(
            pid: positionID,
            existingBorrowed: expectedBorrowAmount,
            existingFLOWCollateral: positionFundingAmount,
            currentFLOWPrice: flowStartPrice,
            depositAmount: amount,
            withdrawIdentifier: MOET_TOKEN_IDENTIFIER,
            depositIdentifier: FLOW_TOKEN_IDENTIFIER
        )

        Test.reset(to: internalSnapshot)
    }

    log("==============================")
}

access(all)
fun testFundsAvailableAboveTargetHealthAfterDepositingWithoutPushFromOvercollateralized() {
    log("==============================")
    log("[TEST] Executing testFundsAvailableAboveTargetHealthAfterDepositingWithoutPushFromOvercollateralized()")

    if snapshot < getCurrentBlockHeight() {
        Test.reset(to: snapshot)
    }

    let openRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [positionFundingAmount, FLOW_VAULT_STORAGE_PATH, false],
        userAccount
    )
    Test.expect(openRes, Test.beSucceeded())
    // assert expected starting point
    let balanceAfterBorrow = getBalance(address: userAccount.address, vaultPublicPath: MOET.VaultPublicPath)!
    let expectedBorrowAmount = 0.0
    Test.assertEqual(expectedBorrowAmount, balanceAfterBorrow)

    let evts = Test.eventsOfType(Type<FlowALPEvents.Opened>())
    let openedEvt = evts[evts.length - 1] as! FlowALPEvents.Opened
    positionID = openedEvt.pid

    let positionDetails = getPositionDetails(pid: positionID, beFailed: false)
    let health = positionDetails.health
    let flowPositionBalance = positionDetails.balances[0]
    Test.assertEqual(positionFundingAmount, flowPositionBalance.balance)
    Test.assertEqual(FlowALPModels.BalanceDirection.Credit, flowPositionBalance.direction)

    let priceIncrease = 0.25
    let newPrice = flowStartPrice * (1.0 + priceIncrease)

    let newCollateralValue = positionFundingAmount * newPrice
    let newEffectiveCollateralValue = newCollateralValue * flowCollateralFactor
    let expectedAvailableAboveTarget = newEffectiveCollateralValue / TARGET_HEALTH * flowBorrowFactor

    setMockOraclePrice(signer: PROTOCOL_ACCOUNT,
        forTokenIdentifier: FLOW_TOKEN_IDENTIFIER,
        price: newPrice
    )
    let actualHealth = getPositionHealth(pid: positionID, beFailed: false)
    Test.assertEqual(CEILING_HEALTH, actualHealth) // no debt should virtually infinite health, capped by UFix64 type

    log("[TEST] FLOW price set to \(newPrice) from \(flowStartPrice)")
    log("[TEST] Position health after price increase: \(actualHealth)")
    log("[TEST] Expected available above target health: \(expectedAvailableAboveTarget) MOET")

    log("..............................")
    // minting to topUpSource Vault which should *not* affect calculation here
    let mintToSource = 1_000.0
    log("[TEST] Minting \(mintToSource) to position topUpSource")
    mintMoet(signer: PROTOCOL_ACCOUNT, to: userAccount.address, amount: mintToSource, beFailed: false)

    log("..............................")
    var depositAmount = 0.0
    var expectedAvailable = (positionFundingAmount + depositAmount) * newPrice * flowCollateralFactor / TARGET_HEALTH * flowBorrowFactor
    var actualAvailable = fundsAvailableAboveTargetHealthAfterDepositing(
            pid: positionID,
            withdrawType: MOET_TOKEN_IDENTIFIER,
            targetHealth: INT_TARGET_HEALTH,
            depositType: FLOW_TOKEN_IDENTIFIER,
            depositAmount: depositAmount,
            beFailed: false
        )
    log("[TEST] Depositing: \(depositAmount)")
    log("[TEST] Expected Available: \(expectedAvailable)")
    log("[TEST] Actual Available: \(actualAvailable)")
    Test.assert(equalWithinVariance(expectedAvailable, actualAvailable),
        message: "Values are not equal within variance - expected: \(expectedAvailable), actual: \(actualAvailable)")

    log("..............................")

    depositAmount = 100.0
    expectedAvailable = expectedAvailableAboveTarget + (depositAmount * flowCollateralFactor / TARGET_HEALTH * flowBorrowFactor) * newPrice
    actualAvailable = fundsAvailableAboveTargetHealthAfterDepositing(
            pid: positionID,
            withdrawType: MOET_TOKEN_IDENTIFIER,
            targetHealth: INT_TARGET_HEALTH,
            depositType: FLOW_TOKEN_IDENTIFIER,
            depositAmount: depositAmount,
            beFailed: false
        )
    log("[TEST] Depositing: \(depositAmount)")
    log("[TEST] Expected Available: \(expectedAvailable)")
    log("[TEST] Actual Available: \(actualAvailable)")
    Test.assert(equalWithinVariance(expectedAvailable, actualAvailable),
        message: "Values are not equal within variance - expected: \(expectedAvailable), actual: \(actualAvailable)")

    log("==============================")
}

/// Demonstrates that the same-type shortcut in fundsAvailableAboveTargetHealthAfterDepositing
/// produces an incorrect (overestimated) result when:
///   1. depositType == withdrawType
///   2. The position holds a Debit balance in that type
///   3. depositAmount > the Debit balance (causing a direction flip from Debit to Credit)
///   4. collateralFactor != borrowFactor for that token
///
/// The shortcut returns  fundsAvailableAboveTargetHealth + depositAmount,
/// assuming a simple additive offset. But when the deposit first repays debt
/// (scaled by 1/borrowFactor) and the excess becomes collateral (scaled by
/// collateralFactor), the two legs have different health impacts.
access(all)
fun testfundsAvailableAboveTargetHealthAfterDepositing_flo15_sameTypeDepositWithdrawLinearizationBug() {
    if snapshot < getCurrentBlockHeight() {
        Test.reset(to: snapshot)
    }

    // --- Setup: LP provides FLOW liquidity, then borrower takes a FLOW loan ---

    // Mint extra FLOW for LP liquidity (setup already minted positionFundingAmount=100)
    mintFlow(to: userAccount, amount: 50.0)

    // LP position (pid 0): deposit 150 FLOW as liquidity
    let lpFlowDeposit = 150.0
    let lpOpenRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [lpFlowDeposit, FLOW_VAULT_STORAGE_PATH, false],
        userAccount
    )
    Test.expect(lpOpenRes, Test.beSucceeded())

    // Mint MOET for the borrower position's collateral
    let moetCollateral = 130.0
    mintMoet(signer: PROTOCOL_ACCOUNT, to: userAccount.address, amount: moetCollateral, beFailed: false)

    // Borrower position (pid 1): deposit MOET as collateral
    let borrowerOpenRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [moetCollateral, MOET.VaultStoragePath, false],
        userAccount
    )
    Test.expect(borrowerOpenRes, Test.beSucceeded())

    // Borrow 110 FLOW against the MOET collateral -> creates FLOW Debit
    let flowDebt = 110.0
    borrowFromPosition(
        signer: userAccount,
        positionId: 1,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        amount: flowDebt,
        beFailed: false
    )

    let borrowerPid: UInt64 = 1

    // Verify initial state
    let details = getPositionDetails(pid: borrowerPid, beFailed: false)
    let moetCredit = getCreditBalanceForType(details: details, vaultType: Type<@MOET.Vault>())
    let flowDebitBal = getDebitBalanceForType(details: details, vaultType: Type<@FlowToken.Vault>())
    Test.assert(equalWithinVariance(moetCollateral, moetCredit), message: "Expected \(moetCollateral) MOET Credit, got \(moetCredit)")
    Test.assert(equalWithinVariance(flowDebt, flowDebitBal), message: "Expected \(flowDebt) FLOW Debit, got \(flowDebitBal)")

    // Call fundsAvailableAboveTargetHealthAfterDepositing with a FLOW deposit exceeding our debit balance and a FLOW withdrawal type
    let depositAmount = 150.0
    let result = fundsAvailableAboveTargetHealthAfterDepositing(
        pid: borrowerPid,
        withdrawType: FLOW_TOKEN_IDENTIFIER,
        targetHealth: INT_TARGET_HEALTH, // 1.3
        depositType: FLOW_TOKEN_IDENTIFIER,
        depositAmount: depositAmount,
        beFailed: false
    )
    log("[TEST] fundsAvailableAboveTargetHealthAfterDepositing returned: \(result)")

    // --- Expected correct result ---
    //
    // After depositing 150 FLOW into a position with 110 FLOW Debit:
    //   - First 110 repays debt entirely  (FLOW Debit -> 0)
    //   - Remaining 40 becomes collateral (FLOW Credit = 40)
    //
    // New effective values (FLOW price=1.0, cf=0.8, bf=1.0):
    //   EC = 130 * 1.0 * 1.0  +  40 * 1.0 * 0.8 = 130 + 32 = 162
    //   ED = 0
    //
    // Max FLOW withdrawal from this state:
    //   Withdraw X <= 40: reduces FLOW Credit, no debt -> health stays infinite
    //   Withdraw X > 40:  FLOW Debit = X - 40
    //     EC = 130 (MOET only)
    //     ED = (X - 40) * 1.0 / 1.0
    //     health = 130 / (X - 40) >= 1.3
    //     X - 40 <= 130 / 1.3 = 100
    //     X <= 140
    //
    // The buggy shortcut does not account for different collateral/borrow factors:
    //   fundsAvailableAboveTargetHealth(FLOW) = 0  (health 1.182 < target 1.3)
    //   shortcut = 0 + 150 = 150   <- WRONG (overestimates by 10)
    //
    let expectedCorrect = (depositAmount - flowDebt) + (moetCollateral / 1.3)
    log("[TEST] Expected correct result: \(expectedCorrect)")
    log("[TEST] Buggy shortcut would return: \(depositAmount)")

    Test.assert(equalWithinVariance(expectedCorrect, result), message: "Same-type linearization bug: expected ~\(expectedCorrect), got \(result).")
}

/* --- Parameterized runner --- */

access(all)
fun runFundsAvailableAboveTargetHealthAfterDepositing(
    pid: UInt64,
    existingBorrowed: UFix64,
    existingFLOWCollateral: UFix64,
    currentFLOWPrice: UFix64,
    depositAmount: UFix64,
    withdrawIdentifier: String,
    depositIdentifier: String
) {
    log("..............................")
    let expectedTotalBorrowCapacity = (existingFLOWCollateral + depositAmount) * currentFLOWPrice * flowCollateralFactor / TARGET_HEALTH * flowBorrowFactor
    let expectedAvailable = expectedTotalBorrowCapacity - existingBorrowed

    let actualAvailable = fundsAvailableAboveTargetHealthAfterDepositing(
            pid: pid,
            withdrawType: withdrawIdentifier,
            targetHealth: INT_TARGET_HEALTH,
            depositType: depositIdentifier,
            depositAmount: depositAmount,
            beFailed: false
        )
    log("[TEST] Withdraw type: \(withdrawIdentifier)")
    log("[TEST] Deposit type: \(depositIdentifier)")
    log("[TEST] Depositing: \(depositAmount)")
    log("[TEST] Expected Available: \(expectedAvailable)")
    log("[TEST] Actual Available: \(actualAvailable)")
    Test.assert(equalWithinVariance(expectedAvailable, actualAvailable),
        message: "Values are not equal within variance - expected: \(expectedAvailable), actual: \(actualAvailable)")
}

// TODO
// - Test depositing withdraw type without pushing to sink, creating a Credit balance before testing
