import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "MOET"
import "FlowALP"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) let protocolConsumerAccount = Test.getAccount(0x0000000000000008)
access(all) let userAccount = Test.createAccount()

access(all) let flowTokenIdentifier = "A.0000000000000003.FlowToken.Vault"
access(all) var moetTokenIdentifier = "A.0000000000000007.MOET.Vault"
access(all) let flowVaultStoragePath = /storage/flowTokenVault
access(all) let wrapperStoragePath = /storage/flowALPPositionWrapper


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
        borrowLimit = (effectiveCollateralValue / targetHealth) * borrowFactor
        borrowLimit = collateralBalance * collateralPrice * collateralFactor / targetHealth * borrowFactor
    Current Health
        borrowedValue = collateralBalance * collateralPrice * collateralFactor / targetHealth * borrowFactor
        borrowedValue * targetHealth = collateralBalance * collateralPrice * collateralFactor * borrowFactor
        health = collateralBalance * collateralPrice * collateralFactor * borrowFactor / borrowedValue
        health = effectiveCollateralValue * borrowFactor / borrowedValue

 */

access(all) let startCollateralValue = flowStartPrice * positionFundingAmount
access(all) let startEffectiveCollateralValue = startCollateralValue * flowCollateralFactor
access(all) let startBorrowLimitAtTarget = startEffectiveCollateralValue / targetHealth

access(all)
fun setup() {

    log("----- SETTING UP funds_available_above_target_health_test.cdc -----")

    deployContracts()

    let betaTxResult = grantBeta(protocolAccount, protocolConsumerAccount)

    Test.expect(betaTxResult, Test.beSucceeded())

    // price setup
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: flowStartPrice)

    // create the Pool & add FLOW as suppoorted token
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: flowCollateralFactor,
        borrowFactor: flowBorrowFactor,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // prep user's account
    setupMoetVault(userAccount, beFailed: false)
    mintFlow(to: userAccount, amount: positionFundingAmount)

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
        "./transactions/mock-flow-alp-consumer/create_wrapped_position.cdc",
        [positionFundingAmount, flowVaultStoragePath, true],
        userAccount
    )
    Test.expect(openRes, Test.beSucceeded())
    // assert expected starting point
    let balanceAfterBorrow = getBalance(address: userAccount.address, vaultPublicPath: MOET.VaultPublicPath)!
    let expectedBorrowAmount = (positionFundingAmount * flowCollateralFactor * flowStartPrice) / targetHealth
    Test.assert(equalWithinVariance(expectedBorrowAmount, balanceAfterBorrow),
        message: "Expected MOET balance to be ~\(expectedBorrowAmount), but got \(balanceAfterBorrow)")

    let evts = Test.eventsOfType(Type<FlowALP.Opened>())
    let openedEvt = evts[evts.length - 1] as! FlowALP.Opened
    positionID = openedEvt.pid

    let positionDetails = getPositionDetails(pid: positionID, beFailed: false)
    let health = positionDetails.health
    let moetBalance = positionDetails.balances[1]
    let flowPositionBalance = positionDetails.balances[0]
    Test.assertEqual(positionFundingAmount, flowPositionBalance.balance)

    Test.assert(equalWithinVariance(expectedBorrowAmount, moetBalance.balance),
        message: "Expected borrow amount to be \(expectedBorrowAmount), but got \(moetBalance.balance)")
    Test.assertEqual(FlowALP.BalanceDirection.Credit, flowPositionBalance.direction)
    Test.assertEqual(FlowALP.BalanceDirection.Debit, moetBalance.direction)

    Test.assert(equalWithinVariance(intTargetHealth, health),
        message: "Expected health to be \(intTargetHealth), but got \(health)")

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
            withdrawIdentifier: moetTokenIdentifier,
            depositIdentifier: flowTokenIdentifier
        )

        // minting to topUpSource Vault which should *not* affect calculation
        let mintToSource = amount < 100.0 ? 100.0 : amount * 10.0
        log("[TEST] Minting \(mintToSource) to position topUpSource and running again")
        mintMoet(signer: protocolAccount, to: userAccount.address, amount: mintToSource, beFailed: false)

        runFundsAvailableAboveTargetHealthAfterDepositing(
            pid: positionID,
            existingBorrowed: expectedBorrowAmount,
            existingFLOWCollateral: positionFundingAmount,
            currentFLOWPrice: flowStartPrice,
            depositAmount: amount,
            withdrawIdentifier: moetTokenIdentifier,
            depositIdentifier: flowTokenIdentifier
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
        "./transactions/mock-flow-alp-consumer/create_wrapped_position.cdc",
        [positionFundingAmount, flowVaultStoragePath, false],
        userAccount
    )
    Test.expect(openRes, Test.beSucceeded())

    // assert expected starting point
    let balanceAfterBorrow = getBalance(address: userAccount.address, vaultPublicPath: MOET.VaultPublicPath)!
    let expectedBorrowAmount = 0.0
    Test.assertEqual(expectedBorrowAmount, balanceAfterBorrow)

    let evts = Test.eventsOfType(Type<FlowALP.Opened>())
    let openedEvt = evts[evts.length - 1] as! FlowALP.Opened
    positionID = openedEvt.pid

    let positionDetails = getPositionDetails(pid: positionID, beFailed: false)
    let health = positionDetails.health
    let flowPositionBalance = positionDetails.balances[0]
    Test.assertEqual(positionFundingAmount, flowPositionBalance.balance)
    Test.assertEqual(FlowALP.BalanceDirection.Credit, flowPositionBalance.direction)

    Test.assertEqual(ceilingHealth, health)

    log("[TEST] FLOW price set to \(flowStartPrice)")

    let amounts: [UFix64] = [0.0, 10.0, 100.0, 1_000.0, 10_000.0, 100_000.0, 1_000_000.0]
    var expectedExcess = 0.0 // none available above target from healthy state
    var expectedDeficit = ((positionFundingAmount * flowCollateralFactor) / targetHealth * flowBorrowFactor) * flowStartPrice

    let internalSnapshot = getCurrentBlockHeight()
    for i, amount in amounts {
        runFundsAvailableAboveTargetHealthAfterDepositing(
            pid: positionID,
            existingBorrowed: expectedBorrowAmount,
            existingFLOWCollateral: positionFundingAmount,
            currentFLOWPrice: flowStartPrice,
            depositAmount: amount,
            withdrawIdentifier: moetTokenIdentifier,
            depositIdentifier: flowTokenIdentifier
        )

        // minting to topUpSource Vault which should *not* affect calculation
        let mintToSource = amount < 100.0 ? 100.0 : amount * 10.0
        log("[TEST] Minting \(mintToSource) to position topUpSource and running again")
        mintMoet(signer: protocolAccount, to: userAccount.address, amount: mintToSource, beFailed: false)

        runFundsAvailableAboveTargetHealthAfterDepositing(
            pid: positionID,
            existingBorrowed: expectedBorrowAmount,
            existingFLOWCollateral: positionFundingAmount,
            currentFLOWPrice: flowStartPrice,
            depositAmount: amount,
            withdrawIdentifier: moetTokenIdentifier,
            depositIdentifier: flowTokenIdentifier
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
        "./transactions/mock-flow-alp-consumer/create_wrapped_position.cdc",
        [positionFundingAmount, flowVaultStoragePath, false],
        userAccount
    )
    Test.expect(openRes, Test.beSucceeded())
    // assert expected starting point
    let balanceAfterBorrow = getBalance(address: userAccount.address, vaultPublicPath: MOET.VaultPublicPath)!
    let expectedBorrowAmount = 0.0
    Test.assertEqual(expectedBorrowAmount, balanceAfterBorrow)

    let evts = Test.eventsOfType(Type<FlowALP.Opened>())
    let openedEvt = evts[evts.length - 1] as! FlowALP.Opened
    positionID = openedEvt.pid

    let positionDetails = getPositionDetails(pid: positionID, beFailed: false)
    let health = positionDetails.health
    let flowPositionBalance = positionDetails.balances[0]
    Test.assertEqual(positionFundingAmount, flowPositionBalance.balance)
    Test.assertEqual(FlowALP.BalanceDirection.Credit, flowPositionBalance.direction)

    let priceIncrease = 0.25
    let newPrice = flowStartPrice * (1.0 + priceIncrease)

    let newCollateralValue = positionFundingAmount * newPrice
    let newEffectiveCollateralValue = newCollateralValue * flowCollateralFactor
    let expectedAvailableAboveTarget = newEffectiveCollateralValue / targetHealth * flowBorrowFactor

    setMockOraclePrice(signer: protocolAccount,
        forTokenIdentifier: flowTokenIdentifier,
        price: newPrice
    )
    let actualHealth = getPositionHealth(pid: positionID, beFailed: false)
    Test.assertEqual(ceilingHealth, actualHealth) // no debt should virtually infinite health, capped by UFix64 type

    log("[TEST] FLOW price set to \(newPrice) from \(flowStartPrice)")
    log("[TEST] Position health after price increase: \(actualHealth)")
    log("[TEST] Expected available above target health: \(expectedAvailableAboveTarget) MOET")

    log("..............................")
    // minting to topUpSource Vault which should *not* affect calculation here
    let mintToSource = 1_000.0
    log("[TEST] Minting \(mintToSource) to position topUpSource")
    mintMoet(signer: protocolAccount, to: userAccount.address, amount: mintToSource, beFailed: false)

    log("..............................")
    var depositAmount = 0.0
    var expectedAvailable = (positionFundingAmount + depositAmount) * newPrice * flowCollateralFactor / targetHealth * flowBorrowFactor
    var actualAvailable = fundsAvailableAboveTargetHealthAfterDepositing(
            pid: positionID,
            withdrawType: moetTokenIdentifier,
            targetHealth: intTargetHealth,
            depositType: flowTokenIdentifier,
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
    expectedAvailable = expectedAvailableAboveTarget + (depositAmount * flowCollateralFactor / targetHealth * flowBorrowFactor) * newPrice
    actualAvailable = fundsAvailableAboveTargetHealthAfterDepositing(
            pid: positionID,
            withdrawType: moetTokenIdentifier,
            targetHealth: intTargetHealth,
            depositType: flowTokenIdentifier,
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

// TODO
// - Test deposit & withdraw same type
// - Test depositing withdraw type without pushing to sink, creating a Credit balance before testing

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
    let expectedTotalBorrowCapacity = (existingFLOWCollateral + depositAmount) * currentFLOWPrice * flowCollateralFactor / targetHealth * flowBorrowFactor
    let expectedAvailable = expectedTotalBorrowCapacity - existingBorrowed

    let actualAvailable = fundsAvailableAboveTargetHealthAfterDepositing(
            pid: pid,
            withdrawType: withdrawIdentifier,
            targetHealth: intTargetHealth,
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
