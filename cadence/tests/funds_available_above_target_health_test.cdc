import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "MOET"
import "TidalProtocol"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) let userAccount = Test.createAccount()

access(all) let flowTokenIdentifier = "A.0000000000000003.FlowToken.Vault"
access(all) var moetTokenIdentifier = "A.0000000000000007.MOET.Vault"
access(all) let flowVaultStoragePath = /storage/flowTokenVault
access(all) let wrapperStoragePath = /storage/tidalProtocolPositionWrapper

access(all) let minHealth = 1.1
access(all) let targetHealth = 1.3
access(all) let maxHealth = 1.5
access(all) let ceilingHealth = UFix64.max
access(all) let flowCollateralFactor = 0.8
access(all) let flowBorrowFactor = 1.0
access(all) let flowStartPrice = 0.5            // denominated in MOET
access(all) let positionFundingAmount = 100.0
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
    log("Executing testFundsAvailableAboveTargetHealthAfterDepositingWithPushFromHealthy()")

    if snapshot < getCurrentBlockHeight() {
        Test.reset(to: snapshot)
    }

    let openRes = executeTransaction(
        "./transactions/mock-tidal-protocol-consumer/create_wrapped_position.cdc",
        [positionFundingAmount, flowVaultStoragePath, true],
        userAccount
    )
    Test.expect(openRes, Test.beSucceeded())
    // assert expected starting point
    let balanceAfterBorrow = getBalance(address: userAccount.address, vaultPublicPath: MOET.VaultPublicPath)!
    let expectedBorrowAmount = (positionFundingAmount * flowCollateralFactor * flowStartPrice) / targetHealth
    // let expectedBorrowAmount = 0.0
    Test.assert(balanceAfterBorrow >= expectedBorrowAmount - 0.01 && balanceAfterBorrow <= expectedBorrowAmount + 0.01,
        message: "Expected MOET balance to be ~\(expectedBorrowAmount), but got \(balanceAfterBorrow)")
    // Test.assertEqual(expectedBorrowAmount, balanceAfterBorrow)

    let evts = Test.eventsOfType(Type<TidalProtocol.Opened>())
    let openedEvt = evts[evts.length - 1] as! TidalProtocol.Opened
    positionID = openedEvt.pid

    let positionDetails = getPositionDetails(pid: positionID, beFailed: false)
    let health = positionDetails.health
    let moetBalance = positionDetails.balances[0]
    let flowBalance = positionDetails.balances[1]
    Test.assertEqual(positionFundingAmount, flowBalance.balance)
    Test.assertEqual(expectedBorrowAmount, moetBalance.balance)
    Test.assertEqual(TidalProtocol.BalanceDirection.Credit, flowBalance.direction)
    Test.assertEqual(TidalProtocol.BalanceDirection.Debit, moetBalance.direction)

    Test.assertEqual(targetHealth, health)
    // Test.assertEqual(ceilingHealth, health)

    log("FLOW price set to \(flowStartPrice)")

    let amounts: [UFix64] = [0.0, 10.0, 100.0, 1_000.0, 10_000.0, 100_000.0, 1_000_000.0]
    let expectedExcess = 0.0 // none available above target from healthy state

    let internalSnapshot = getCurrentBlockHeight()
    for i, amount in amounts {
        runFundsAvailableAboveTargetHealthAfterDepositing(
            pid: positionID,
            existingBorrowed: expectedBorrowAmount,
            existingFlowCollateral: positionFundingAmount,
            currentFlowPrice: flowStartPrice,
            depositAmount: amount,
            withdrawIdentifier: moetTokenIdentifier,
            depositIdentifier: flowTokenIdentifier
        )

        // minting to topUpSource Vault which should *not* affect calculation
        let mintToSource = amount < 100.0 ? 100.0 : amount * 10.0
        log("Minting \(mintToSource) to position topUpSource and running again")
        mintMoet(signer: protocolAccount, to: userAccount.address, amount: mintToSource, beFailed: false)

        runFundsAvailableAboveTargetHealthAfterDepositing(
            pid: positionID,
            existingBorrowed: expectedBorrowAmount,
            existingFlowCollateral: positionFundingAmount,
            currentFlowPrice: flowStartPrice,
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
    log("Executing testFundsAvailableAboveTargetHealthAfterDepositingWithoutPushFromHealthy()")

    if snapshot < getCurrentBlockHeight() {
        Test.reset(to: snapshot)
    }

    let openRes = executeTransaction(
        "./transactions/mock-tidal-protocol-consumer/create_wrapped_position.cdc",
        [positionFundingAmount, flowVaultStoragePath, false],
        userAccount
    )
    Test.expect(openRes, Test.beSucceeded())

    // assert expected starting point
    let balanceAfterBorrow = getBalance(address: userAccount.address, vaultPublicPath: MOET.VaultPublicPath)!
    let expectedBorrowAmount = 0.0
    Test.assertEqual(expectedBorrowAmount, balanceAfterBorrow)

    let evts = Test.eventsOfType(Type<TidalProtocol.Opened>())
    let openedEvt = evts[evts.length - 1] as! TidalProtocol.Opened
    positionID = openedEvt.pid

    let positionDetails = getPositionDetails(pid: positionID, beFailed: false)
    let health = positionDetails.health
    let flowBalance = positionDetails.balances[0]
    Test.assertEqual(positionFundingAmount, flowBalance.balance)
    Test.assertEqual(TidalProtocol.BalanceDirection.Credit, flowBalance.direction)

    Test.assertEqual(ceilingHealth, health)

    log("FLOW price set to \(flowStartPrice)")

    let amounts: [UFix64] = [0.0, 10.0, 100.0, 1_000.0, 10_000.0, 100_000.0, 1_000_000.0]
    var expectedExcess = 0.0 // none available above target from healthy state
    var expectedDeficit = ((positionFundingAmount * flowCollateralFactor) / targetHealth * flowBorrowFactor) * flowStartPrice

    let internalSnapshot = getCurrentBlockHeight()
    for i, amount in amounts {
        runFundsAvailableAboveTargetHealthAfterDepositing(
            pid: positionID,
            existingBorrowed: expectedBorrowAmount,
            existingFlowCollateral: positionFundingAmount,
            currentFlowPrice: flowStartPrice,
            depositAmount: amount,
            withdrawIdentifier: moetTokenIdentifier,
            depositIdentifier: flowTokenIdentifier
        )

        // minting to topUpSource Vault which should *not* affect calculation
        let mintToSource = amount < 100.0 ? 100.0 : amount * 10.0
        log("Minting \(mintToSource) to position topUpSource and running again")
        mintMoet(signer: protocolAccount, to: userAccount.address, amount: mintToSource, beFailed: false)

        runFundsAvailableAboveTargetHealthAfterDepositing(
            pid: positionID,
            existingBorrowed: expectedBorrowAmount,
            existingFlowCollateral: positionFundingAmount,
            currentFlowPrice: flowStartPrice,
            depositAmount: amount,
            withdrawIdentifier: moetTokenIdentifier,
            depositIdentifier: flowTokenIdentifier
        )

        Test.reset(to: internalSnapshot)
    }

    log("==============================")
}

// TODO
// - Test deposit & withdraw same type
// - Test depositing withdraw type without pushing to sink, creating a Credit balance before testing`

/* --- Parameterized runner --- */

access(all)
fun runFundsAvailableAboveTargetHealthAfterDepositing(
    pid: UInt64,
    existingBorrowed: UFix64,
    existingFlowCollateral: UFix64,
    currentFlowPrice: UFix64,
    depositAmount: UFix64,
    withdrawIdentifier: String,
    depositIdentifier: String
) {
    log("..............................")
    let expectedTotalBorrowCapacity = (existingFlowCollateral + depositAmount) * currentFlowPrice * flowCollateralFactor / targetHealth * flowBorrowFactor
    let expectedAvailable = expectedTotalBorrowCapacity - existingBorrowed

    let actualAvailable = fundsAvailableAboveTargetHealthAfterDepositing(
            pid: pid,
            withdrawType: withdrawIdentifier,
            targetHealth: targetHealth,
            depositType: depositIdentifier,
            depositAmount: depositAmount,
            beFailed: false
        )
    log("Withdraw type: \(withdrawIdentifier)")
    log("Deposit type: \(depositIdentifier)")
    log("Depositing: \(depositAmount)")
    log("Expected Available: \(expectedAvailable)")
    log("Actual Available: \(actualAvailable)")
    Test.assert(equalWithinVariance(expectedAvailable, actualAvailable, plusMinus: nil),
        message: "Values are not equal within variance - expected: \(expectedAvailable), actual: \(actualAvailable)")
}