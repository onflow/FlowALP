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
access(all) let flowCollateralFactor = 0.8
access(all) let flowBorrowFactor = 1.0
access(all) let flowStartPrice = 1.0            // denominated in MOET
access(all) let positionFundingAmount = 100.0
access(all) var positionID: UInt64 = 0

access(all) let startCollateralValue = flowStartPrice * positionFundingAmount
access(all) let startEffectiveCollateralValue = startCollateralValue * flowCollateralFactor
access(all) let startBorrowLimitAtTarget = startEffectiveCollateralValue / targetHealth

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
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

    let openRes = executeTransaction(
        "./transactions/mock-tidal-protocol-consumer/create_wrapped_position.cdc",
        [positionFundingAmount, flowVaultStoragePath, true],
        userAccount
    )
    Test.expect(openRes, Test.beSucceeded())
    // assert expected starting point
    let balanceAfterBorrow = getBalance(address: userAccount.address, vaultPublicPath: MOET.VaultPublicPath)!
    let expectedBorrowAmount = (positionFundingAmount * flowCollateralFactor) / targetHealth
    Test.assert(balanceAfterBorrow >= expectedBorrowAmount - 0.01 && balanceAfterBorrow <= expectedBorrowAmount + 0.01,
        message: "Expected MOET balance to be ~\(expectedBorrowAmount), but got \(balanceAfterBorrow)")

    let evts = Test.eventsOfType(Type<TidalProtocol.Opened>())
    let openedEvt = evts[evts.length - 1] as! TidalProtocol.Opened
    positionID = openedEvt.pid

    let health = getPositionHealth(pid: positionID, beFailed: false)
    Test.assertEqual(targetHealth, health)

    snapshot = getCurrentBlockHeight()
}

access(all)
fun testFundsAvailableAboveTargetHealthAfterDepositingFromHealthy() {
    log("==============================")
    log("Executing testFundsAvailableAboveTargetHealthAfterDepositingFromHealthy()")

    log("FLOW price set to \(flowStartPrice)")

    log("..............................")
    var depositAmount = 0.0
    var expectedAvailable = 0.0 // already at target health - nothing additional available
    var actualAvailable = fundsAvailableAboveTargetHealthAfterDepositing(
            pid: positionID,
            withdrawType: moetTokenIdentifier,
            targetHealth: targetHealth,
            depositType: flowTokenIdentifier,
            depositAmount: depositAmount,
            beFailed: false
        )
    log("Depositing: \(depositAmount)")
    log("Expected Available: \(expectedAvailable)")
    log("Actual Available: \(actualAvailable)")
    Test.assert(equalWithinVariance(expectedAvailable, actualAvailable, plusMinus: nil))

    log("..............................")
    depositAmount = 100.0
    expectedAvailable = ((depositAmount * flowCollateralFactor) / targetHealth) * flowStartPrice
    actualAvailable = fundsAvailableAboveTargetHealthAfterDepositing(
            pid: positionID,
            withdrawType: moetTokenIdentifier,
            targetHealth: targetHealth,
            depositType: flowTokenIdentifier,
            depositAmount: depositAmount,
            beFailed: false
        )
    log("Depositing: \(depositAmount)")
    log("Expected Available: \(expectedAvailable)")
    log("Actual Available: \(actualAvailable)")
    Test.assert(equalWithinVariance(expectedAvailable, actualAvailable, plusMinus: nil))

    log("..............................")
    depositAmount = 1_000.0
    expectedAvailable = ((depositAmount * flowCollateralFactor) / targetHealth) * flowStartPrice
    actualAvailable = fundsAvailableAboveTargetHealthAfterDepositing(
            pid: positionID,
            withdrawType: moetTokenIdentifier,
            targetHealth: targetHealth,
            depositType: flowTokenIdentifier,
            depositAmount: depositAmount,
            beFailed: false
        )
    log("Depositing: \(depositAmount)")
    log("Expected Available: \(expectedAvailable)")
    log("Actual Available: \(actualAvailable)")
    Test.assert(equalWithinVariance(expectedAvailable, actualAvailable, plusMinus: nil))

    log("..............................")
    depositAmount = 10_000.0
    expectedAvailable = ((depositAmount * flowCollateralFactor) / targetHealth) * flowStartPrice
    actualAvailable = fundsAvailableAboveTargetHealthAfterDepositing(
            pid: positionID,
            withdrawType: moetTokenIdentifier,
            targetHealth: targetHealth,
            depositType: flowTokenIdentifier,
            depositAmount: depositAmount,
            beFailed: false
        )
    log("Depositing: \(depositAmount)")
    log("Expected Available: \(expectedAvailable)")
    log("Actual Available: \(actualAvailable)")
    Test.assert(equalWithinVariance(expectedAvailable, actualAvailable, plusMinus: nil))

    log("..............................")
    depositAmount = 100_000.0
    expectedAvailable = ((depositAmount * flowCollateralFactor) / targetHealth) * flowStartPrice
    actualAvailable = fundsAvailableAboveTargetHealthAfterDepositing(
            pid: positionID,
            withdrawType: moetTokenIdentifier,
            targetHealth: targetHealth,
            depositType: flowTokenIdentifier,
            depositAmount: depositAmount,
            beFailed: false
        )
    log("Depositing: \(depositAmount)")
    log("Expected Available: \(expectedAvailable)")
    log("Actual Available: \(actualAvailable)")
    Test.assert(equalWithinVariance(expectedAvailable, actualAvailable, plusMinus: nil))

    log("..............................")
    depositAmount = 1_000_000.0
    expectedAvailable = ((depositAmount * flowCollateralFactor) / targetHealth) * flowStartPrice
    actualAvailable = fundsAvailableAboveTargetHealthAfterDepositing(
            pid: positionID,
            withdrawType: moetTokenIdentifier,
            targetHealth: targetHealth,
            depositType: flowTokenIdentifier,
            depositAmount: depositAmount,
            beFailed: false
        )
    log("Depositing: \(depositAmount)")
    log("Expected Available: \(expectedAvailable)")
    log("Actual Available: \(actualAvailable)")
    Test.assert(equalWithinVariance(expectedAvailable, actualAvailable, plusMinus: nil))

    log("==============================")
}

access(all)
fun testFundsAvailableAboveTargetHealthAfterDepositingFromUndercollateralized() {
    log("==============================")
    log("Executing testFundsAvailableAboveTargetHealthAfterDepositingFromUndercollateralized()")

    let priceDecrease = 0.25
    let newPrice = flowStartPrice * (1.0 - priceDecrease)

    let newCollateralValue = positionFundingAmount * newPrice
    let newEffectiveCollateralValue = newCollateralValue * flowCollateralFactor
    let newBorrowLimitAtTarget = newEffectiveCollateralValue / targetHealth
    let expectedDepositRequiredForTarget = startBorrowLimitAtTarget - newBorrowLimitAtTarget

    setMockOraclePrice(signer: protocolAccount,
        forTokenIdentifier: flowTokenIdentifier,
        price: newPrice
    )
    let actualHealth = getPositionHealth(pid: positionID, beFailed: false)
    Test.assertEqual(targetHealth * (1.0 - priceDecrease), actualHealth)

    log("FLOW price set to \(newPrice) from \(flowStartPrice)")
    log("Position health after price decrease: \(actualHealth)")
    log("Expected deposit required for target health: \(expectedDepositRequiredForTarget)")

    log("..............................")
    // minting to topUpSource Vault which should *not* affect calculation here
    let mintToSource = 100.0
    log("Minting \(mintToSource) to position topUpSource")
    mintMoet(signer: protocolAccount, to: userAccount.address, amount: mintToSource, beFailed: false)

    log("..............................")
    var depositAmount = 0.0
    var expectedAvailable = 0.0 // already below target health - nothing available
    var actualAvailable = fundsAvailableAboveTargetHealthAfterDepositing(
            pid: positionID,
            withdrawType: moetTokenIdentifier,
            targetHealth: targetHealth,
            depositType: flowTokenIdentifier,
            depositAmount: depositAmount,
            beFailed: false
        )
    log("Depositing: \(depositAmount)")
    log("Expected Available: \(expectedAvailable)")
    log("Actual Available: \(actualAvailable)")
    Test.assert(equalWithinVariance(expectedAvailable, actualAvailable, plusMinus: nil))

    log("..............................")
    let surplusDeposit = 1.0
    depositAmount = expectedDepositRequiredForTarget + surplusDeposit
    expectedAvailable = (surplusDeposit * flowCollateralFactor / targetHealth) * newPrice
    actualAvailable = fundsAvailableAboveTargetHealthAfterDepositing(
            pid: positionID,
            withdrawType: moetTokenIdentifier,
            targetHealth: targetHealth,
            depositType: flowTokenIdentifier,
            depositAmount: depositAmount,
            beFailed: false
        )
    log("Depositing: \(depositAmount)")
    log("Expected Available: \(expectedAvailable)")
    log("Actual Available: \(actualAvailable)")
    Test.assert(equalWithinVariance(expectedAvailable, actualAvailable, plusMinus: nil))

    log("==============================")
}

access(all)
fun testFundsAvailableAboveTargetHealthAfterDepositingFromOvercollateralized() {
    log("==============================")
    log("Executing testFundsAvailableAboveTargetHealthAfterDepositingFromOvercollateralized()")

    let priceIncrease = 0.25
    let newPrice = flowStartPrice * (1.0 + priceIncrease)

    let newCollateralValue = positionFundingAmount * newPrice
    let newEffectiveCollateralValue = newCollateralValue * flowCollateralFactor
    let newBorrowLimitAtTarget = newEffectiveCollateralValue / targetHealth
    let expectedAvailableAboveTarget = newBorrowLimitAtTarget - startBorrowLimitAtTarget

    setMockOraclePrice(signer: protocolAccount,
        forTokenIdentifier: flowTokenIdentifier,
        price: newPrice
    )
    let actualHealth = getPositionHealth(pid: positionID, beFailed: false)
    Test.assertEqual(targetHealth * (1.0 + priceIncrease), actualHealth)

    log("FLOW price set to \(newPrice) from \(flowStartPrice)")
    log("Position health after price decrease: \(actualHealth)")
    log("Expected availabe above target health: \(expectedAvailableAboveTarget)")

    log("..............................")
    // minting to topUpSource Vault which should *not* affect calculation here
    let mintToSource = 100.0
    log("Minting \(mintToSource) to position topUpSource")
    mintMoet(signer: protocolAccount, to: userAccount.address, amount: mintToSource, beFailed: false)

    log("..............................")
    var depositAmount = 0.0
    var expectedAvailable = expectedAvailableAboveTarget * newPrice
    var actualAvailable = fundsAvailableAboveTargetHealthAfterDepositing(
            pid: positionID,
            withdrawType: moetTokenIdentifier,
            targetHealth: targetHealth,
            depositType: flowTokenIdentifier,
            depositAmount: depositAmount,
            beFailed: false
        )
    log("Depositing: \(depositAmount)")
    log("Expected Available: \(expectedAvailable)")
    log("Actual Available: \(actualAvailable)")
    Test.assert(equalWithinVariance(expectedAvailable, actualAvailable, plusMinus: nil))

    log("..............................")
    depositAmount = 100.0
    expectedAvailable = (expectedAvailableAboveTarget + depositAmount) * newPrice
    actualAvailable = fundsAvailableAboveTargetHealthAfterDepositing(
            pid: positionID,
            withdrawType: moetTokenIdentifier,
            targetHealth: targetHealth,
            depositType: flowTokenIdentifier,
            depositAmount: depositAmount,
            beFailed: false
        )
    log("Depositing: \(depositAmount)")
    log("Expected Available: \(expectedAvailable)")
    log("Actual Available: \(actualAvailable)")
    Test.assert(equalWithinVariance(expectedAvailable, actualAvailable, plusMinus: nil))

    log("==============================")
}