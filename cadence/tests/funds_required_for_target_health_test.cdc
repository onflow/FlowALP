import Test
import BlockchainHelpers

import "test_helpers.cdc"

import "MOET"
import "FlowCreditMarket"
import "FlowCreditMarketMath"

access(all) let userAccount = Test.createAccount()

access(all) let flowCollateralFactor = 0.8
access(all) let flowBorrowFactor = 1.0
access(all) let flowStartPrice = 0.5
access(all) let positionFundingAmount = 100.0
access(all) var positionID: UInt64 = 0
access(all) var startingDebt = 0.0

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
    deployContracts()

    let betaTxResult = grantBeta(protocolAccount, consumerAccount)

    Test.expect(betaTxResult, Test.beSucceeded())

    // price setup
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: flowStartPrice)

    // create the Pool & add FLOW as suppoorted token
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: moetTokenIdentifier, beFailed: false)
    addSupportedTokenZeroRateCurve(
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
}

access(all)
fun testFundsRequiredForTargetHealthAfterWithdrawingWithPushFromHealthy() {
    log("==============================")
    log("[TEST] Executing testFundsRequiredForTargetHealthAfterWithdrawingWithPushFromHealthy()")

    if snapshot < getCurrentBlockHeight() {
        Test.reset(to: snapshot)
    }

    let openRes = executeTransaction(
        "./transactions/mock-flow-credit-market-consumer/create_wrapped_position.cdc",
        [positionFundingAmount, flowVaultStoragePath, true],
        userAccount
    )
    Test.expect(openRes, Test.beSucceeded())
    // assert expected starting point
    startingDebt = getBalance(address: userAccount.address, vaultPublicPath: MOET.VaultPublicPath)!
    let expectedStartingDebt = (positionFundingAmount * flowCollateralFactor * flowStartPrice) / targetHealth
    Test.assert(equalWithinVariance(expectedStartingDebt, startingDebt),
        message: "Expected MOET balance to be ~\(expectedStartingDebt), but got \(startingDebt)")

    var evts = Test.eventsOfType(Type<FlowCreditMarket.Opened>())
    let openedEvt = evts[evts.length - 1] as! FlowCreditMarket.Opened
    positionID = openedEvt.pid

    // when position is opened, depositAndPush == true should trigger a rebalance, pushing MOET to user's Vault
    evts = Test.eventsOfType(Type<FlowCreditMarket.Rebalanced>())
    let rebalancedEvt = evts[evts.length - 1] as! FlowCreditMarket.Rebalanced
    Test.assertEqual(positionID, rebalancedEvt.pid)
    Test.assertEqual(startingDebt, rebalancedEvt.amount)
    Test.assertEqual(rebalancedEvt.amount, startingDebt)

    let health = getPositionHealth(pid: positionID, beFailed: false)
    Test.assert(equalWithinVariance(intTargetHealth, health),
        message: "Expected health to be \(intTargetHealth), but got \(health)")

    log("[TEST] FLOW price set to \(flowStartPrice)")

    let amounts: [UFix64] = [0.0, 10.0, 100.0, 1_000.0, 10_000.0, 100_000.0]

    let internalSnapshot = getCurrentBlockHeight()
    for i, amount in amounts {
        // minting to topUpSource Vault which should *not* affect calculation
        let mintToSource = amount < 100.0 ? 100.0 : amount * 10.0
        log("[TEST] Minting \(mintToSource) to position topUpSource and running again")
        mintMoet(signer: protocolAccount, to: userAccount.address, amount: mintToSource, beFailed: false)
        runFundsRequiredForTargetHealthAfterWithdrawing(
            pid: positionID,
            existingFLOWCollateral: positionFundingAmount,
            existingBorrowed: startingDebt,
            currentFLOWPrice: flowStartPrice,
            depositIdentifier: flowTokenIdentifier,
            withdrawIdentifier: moetTokenIdentifier,
            withdrawAmount: amount
        )

        Test.reset(to: internalSnapshot)
    }

    log("==============================")
}

access(all)
fun testFundsRequiredForTargetHealthAfterWithdrawingWithoutPushFromHealthy() {
    log("==============================")
    log("[TEST] Executing testFundsRequiredForTargetHealthAfterWithdrawingWithoutPushFromHealthy()")

    if snapshot < getCurrentBlockHeight() {
        Test.reset(to: snapshot)
    }

    let openRes = executeTransaction(
        "./transactions/mock-flow-credit-market-consumer/create_wrapped_position.cdc",
        [positionFundingAmount, flowVaultStoragePath, false],
        userAccount
    )
    Test.expect(openRes, Test.beSucceeded())
    // assert expected starting point
    startingDebt = getBalance(address: userAccount.address, vaultPublicPath: MOET.VaultPublicPath)!
    let expectedStartingDebt = 0.0
    Test.assert(expectedStartingDebt == startingDebt,
        message: "Expected MOET balance to be ~\(expectedStartingDebt), but got \(startingDebt)")

    var evts = Test.eventsOfType(Type<FlowCreditMarket.Opened>())
    let openedEvt = evts[evts.length - 1] as! FlowCreditMarket.Opened
    positionID = openedEvt.pid

    // when position is opened, depositAndPush == true should trigger a rebalance, pushing MOET to user's Vault
    evts = Test.eventsOfType(Type<FlowCreditMarket.Rebalanced>())
    Test.assert(evts.length == 0, message: "Expected no rebalanced events, but got \(evts.length)")

    let health = getPositionHealth(pid: positionID, beFailed: false)
    Test.assert(ceilingHealth == health,
        message: "Expected health to be \(intTargetHealth), but got \(health)")

    log("[TEST] FLOW price set to \(flowStartPrice)")

    let amounts: [UFix64] = [0.0, 10.0, 100.0, 1_000.0]

    let internalSnapshot = getCurrentBlockHeight()
    for i, amount in amounts {
        // minting to topUpSource Vault which should *not* affect calculation
        let mintToSource = amount < 100.0 ? 100.0 : amount * 10.0
        log("[TEST] Minting \(mintToSource) to position topUpSource and running again")
        mintMoet(signer: protocolAccount, to: userAccount.address, amount: mintToSource, beFailed: false)
        runFundsRequiredForTargetHealthAfterWithdrawing(
            pid: positionID,
            existingFLOWCollateral: positionFundingAmount,
            existingBorrowed: startingDebt,
            currentFLOWPrice: flowStartPrice,
            depositIdentifier: flowTokenIdentifier,
            withdrawIdentifier: moetTokenIdentifier,
            withdrawAmount: amount
        )

        Test.reset(to: internalSnapshot)
    }

    log("==============================")
}

access(all)
fun testFundsRequiredForTargetHealthAfterWithdrawingWithoutPushFromOvercollateralized() {
    log("==============================")
    log("[TEST] Executing testFundsRequiredForTargetHealthAfterWithdrawingWithoutPushFromOvercollateralized()")

    if snapshot < getCurrentBlockHeight() {
        Test.reset(to: snapshot)
    }

    let openRes = executeTransaction(
        "./transactions/mock-flow-credit-market-consumer/create_wrapped_position.cdc",
        [positionFundingAmount, flowVaultStoragePath, false],
        userAccount
    )
    Test.expect(openRes, Test.beSucceeded())
    // assert expected starting point
    startingDebt = getBalance(address: userAccount.address, vaultPublicPath: MOET.VaultPublicPath)!
    let expectedStartingDebt = 0.0
    Test.assert(expectedStartingDebt == startingDebt,
        message: "Expected MOET balance to be ~\(expectedStartingDebt), but got \(startingDebt)")

    var evts = Test.eventsOfType(Type<FlowCreditMarket.Opened>())
    let openedEvt = evts[evts.length - 1] as! FlowCreditMarket.Opened
    positionID = openedEvt.pid

    // when position is opened, depositAndPush == true should trigger a rebalance, pushing MOET to user's Vault
    evts = Test.eventsOfType(Type<FlowCreditMarket.Rebalanced>())
    Test.assert(evts.length == 0, message: "Expected no rebalanced events, but got \(evts.length)")

    let health = getPositionHealth(pid: positionID, beFailed: false)
    Test.assert(ceilingHealth == health,
        message: "Expected health to be \(intTargetHealth), but got \(health)")

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

    let amounts: [UFix64] = [0.0, 10.0, 100.0, 1_000.0]

    let internalSnapshot = getCurrentBlockHeight()
    for i, amount in amounts {
        // minting to topUpSource Vault which should *not* affect calculation
        let mintToSource = amount < 100.0 ? 100.0 : amount * 10.0
        log("[TEST] Minting \(mintToSource) to position topUpSource and running again")
        mintMoet(signer: protocolAccount, to: userAccount.address, amount: mintToSource, beFailed: false)
        runFundsRequiredForTargetHealthAfterWithdrawing(
            pid: positionID,
            existingFLOWCollateral: positionFundingAmount,
            existingBorrowed: startingDebt,
            currentFLOWPrice: newPrice,
            depositIdentifier: flowTokenIdentifier,
            withdrawIdentifier: moetTokenIdentifier,
            withdrawAmount: amount
        )

        Test.reset(to: internalSnapshot)
    }

    log("==============================")
}

access(all)
fun testFundsRequiredForTargetHealthAfterWithdrawingWithPushFromOvercollateralized() {
    log("==============================")
    log("[TEST] Executing testFundsRequiredForTargetHealthAfterWithdrawingWithPushFromOvercollateralized()")

    if snapshot < getCurrentBlockHeight() {
        Test.reset(to: snapshot)
    }

    let openRes = executeTransaction(
        "./transactions/mock-flow-credit-market-consumer/create_wrapped_position.cdc",
        [positionFundingAmount, flowVaultStoragePath, true],
        userAccount
    )
    Test.expect(openRes, Test.beSucceeded())
    // assert expected starting point
    startingDebt = getBalance(address: userAccount.address, vaultPublicPath: MOET.VaultPublicPath)!
    let expectedStartingDebt = (positionFundingAmount * flowCollateralFactor * flowStartPrice) / targetHealth
    Test.assert(equalWithinVariance(expectedStartingDebt, startingDebt),
        message: "Expected MOET balance to be ~\(expectedStartingDebt), but got \(startingDebt)")

    var evts = Test.eventsOfType(Type<FlowCreditMarket.Opened>())
    let openedEvt = evts[evts.length - 1] as! FlowCreditMarket.Opened
    positionID = openedEvt.pid

    // when position is opened, depositAndPush == true should trigger a rebalance, pushing MOET to user's Vault
    evts = Test.eventsOfType(Type<FlowCreditMarket.Rebalanced>())
    let rebalancedEvt = evts[evts.length - 1] as! FlowCreditMarket.Rebalanced
    Test.assertEqual(positionID, rebalancedEvt.pid)
    Test.assertEqual(startingDebt, rebalancedEvt.amount)
    Test.assertEqual(rebalancedEvt.amount, startingDebt)

    let actualHealthBeforePriceIncrease = getPositionHealth(pid: positionID, beFailed: false)
    Test.assert(equalWithinVariance(intTargetHealth, actualHealthBeforePriceIncrease),
        message: "Expected health to be \(intTargetHealth), but got \(actualHealthBeforePriceIncrease)")

    let priceIncrease = 0.25
    let newPrice = flowStartPrice * (1.0 + priceIncrease)

    let newCollateralValue = positionFundingAmount * newPrice
    let newEffectiveCollateralValue = newCollateralValue * flowCollateralFactor
    let expectedAvailableAboveTarget = newEffectiveCollateralValue / targetHealth * flowBorrowFactor

    setMockOraclePrice(signer: protocolAccount,
        forTokenIdentifier: flowTokenIdentifier,
        price: newPrice
    )
    let actualHealthAfterPriceIncrease = getPositionHealth(pid: positionID, beFailed: false)
    // calculate new health based on updated collateral value - should increase proportionally to price increase
    let expectedHealthAfterPriceIncrease = actualHealthBeforePriceIncrease * UFix128(1.0 + priceIncrease)
    Test.assertEqual(expectedHealthAfterPriceIncrease, actualHealthAfterPriceIncrease)

    log("[TEST] FLOW price set to \(newPrice) from \(flowStartPrice)")
    log("[TEST] Position health after price increase: \(actualHealthAfterPriceIncrease)")
    log("[TEST] Expected available above target health: \(expectedAvailableAboveTarget) MOET")

    let amounts: [UFix64] = [0.0, 10.0, 100.0, 1_000.0]

    let internalSnapshot = getCurrentBlockHeight()
    for i, amount in amounts {
        // minting to topUpSource Vault which should *not* affect calculation
        let mintToSource = amount < 100.0 ? 100.0 : amount * 10.0
        log("[TEST] Minting \(mintToSource) to position topUpSource and running again")
        mintMoet(signer: protocolAccount, to: userAccount.address, amount: mintToSource, beFailed: false)
        runFundsRequiredForTargetHealthAfterWithdrawing(
            pid: positionID,
            existingFLOWCollateral: positionFundingAmount,
            existingBorrowed: startingDebt,
            currentFLOWPrice: newPrice,
            depositIdentifier: flowTokenIdentifier,
            withdrawIdentifier: moetTokenIdentifier,
            withdrawAmount: amount
        )

        Test.reset(to: internalSnapshot)
    }

    log("==============================")
}

access(all)
fun testFundsRequiredForTargetHealthAfterWithdrawingWithoutPushFromUndercollateralized() {
    log("==============================")
    log("[TEST] Executing testFundsRequiredForTargetHealthAfterWithdrawingWithoutPushFromUndercollateralized()")

    if snapshot < getCurrentBlockHeight() {
        Test.reset(to: snapshot)
    }

    let openRes = executeTransaction(
        "./transactions/mock-flow-credit-market-consumer/create_wrapped_position.cdc",
        [positionFundingAmount, flowVaultStoragePath, false],
        userAccount
    )
    Test.expect(openRes, Test.beSucceeded())
    // assert expected starting point
    startingDebt = getBalance(address: userAccount.address, vaultPublicPath: MOET.VaultPublicPath)!
    let expectedStartingDebt = 0.0
    Test.assert(expectedStartingDebt == startingDebt,
        message: "Expected MOET balance to be ~\(expectedStartingDebt), but got \(startingDebt)")

    var evts = Test.eventsOfType(Type<FlowCreditMarket.Opened>())
    let openedEvt = evts[evts.length - 1] as! FlowCreditMarket.Opened
    positionID = openedEvt.pid

    // when position is opened, depositAndPush == true should trigger a rebalance, pushing MOET to user's Vault
    evts = Test.eventsOfType(Type<FlowCreditMarket.Rebalanced>())
    Test.assert(evts.length == 0, message: "Expected no rebalanced events, but got \(evts.length)")

    let actualHealthBeforePriceDecrease = getPositionHealth(pid: positionID, beFailed: false)
    Test.assert(ceilingHealth == actualHealthBeforePriceDecrease,
        message: "Expected health to be \(intTargetHealth), but got \(actualHealthBeforePriceDecrease)")

    let priceDecrease = 0.25
    let newPrice = flowStartPrice * (1.0 - priceDecrease)

    let newCollateralValue = positionFundingAmount * newPrice
    let newEffectiveCollateralValue = newCollateralValue * flowCollateralFactor
    let expectedAvailableAboveTarget = newEffectiveCollateralValue / targetHealth * flowBorrowFactor

    setMockOraclePrice(signer: protocolAccount,
        forTokenIdentifier: flowTokenIdentifier,
        price: newPrice
    )
    let actualHealthAfterPriceDecrease = getPositionHealth(pid: positionID, beFailed: false)
    Test.assertEqual(ceilingHealth, actualHealthAfterPriceDecrease) // no debt should virtually infinite health, capped by UFix64 type

    log("[TEST] FLOW price set to \(newPrice) from \(flowStartPrice)")
    log("[TEST] Position health after price decrease: \(actualHealthAfterPriceDecrease)")
    log("[TEST] Expected available above target health: \(expectedAvailableAboveTarget) MOET")

    let amounts: [UFix64] = [0.0, 10.0, 100.0, 1_000.0]

    let internalSnapshot = getCurrentBlockHeight()
    for i, amount in amounts {
        // minting to topUpSource Vault which should *not* affect calculation
        let mintToSource = amount < 100.0 ? 100.0 : amount * 10.0
        log("[TEST] Minting \(mintToSource) to position topUpSource and running again")
        mintMoet(signer: protocolAccount, to: userAccount.address, amount: mintToSource, beFailed: false)
        runFundsRequiredForTargetHealthAfterWithdrawing(
            pid: positionID,
            existingFLOWCollateral: positionFundingAmount,
            existingBorrowed: startingDebt,
            currentFLOWPrice: newPrice,
            depositIdentifier: flowTokenIdentifier,
            withdrawIdentifier: moetTokenIdentifier,
            withdrawAmount: amount
        )

        Test.reset(to: internalSnapshot)
    }

    log("==============================")
}

access(all)
fun testFundsRequiredForTargetHealthAfterWithdrawingWithPushFromUndercollateralized() {
    log("==============================")
    log("[TEST] Executing testFundsRequiredForTargetHealthAfterWithdrawingWithPushFromUndercollateralized()")

    if snapshot < getCurrentBlockHeight() {
        Test.reset(to: snapshot)
    }

    let openRes = executeTransaction(
        "./transactions/mock-flow-credit-market-consumer/create_wrapped_position.cdc",
        [positionFundingAmount, flowVaultStoragePath, true],
        userAccount
    )
    Test.expect(openRes, Test.beSucceeded())
    // assert expected starting point
    startingDebt = getBalance(address: userAccount.address, vaultPublicPath: MOET.VaultPublicPath)!
    let expectedStartingDebt = (positionFundingAmount * flowCollateralFactor * flowStartPrice) / targetHealth
    Test.assert(equalWithinVariance(expectedStartingDebt, startingDebt),
        message: "Expected MOET balance to be ~\(expectedStartingDebt), but got \(startingDebt)")

    var evts = Test.eventsOfType(Type<FlowCreditMarket.Opened>())
    let openedEvt = evts[evts.length - 1] as! FlowCreditMarket.Opened
    positionID = openedEvt.pid

    // when position is opened, depositAndPush == true should trigger a rebalance, pushing MOET to user's Vault
    evts = Test.eventsOfType(Type<FlowCreditMarket.Rebalanced>())
    let rebalancedEvt = evts[evts.length - 1] as! FlowCreditMarket.Rebalanced
    Test.assertEqual(positionID, rebalancedEvt.pid)
    Test.assertEqual(startingDebt, rebalancedEvt.amount)
    Test.assertEqual(rebalancedEvt.amount, startingDebt)

    let actualHealthBeforePriceIncrease = getPositionHealth(pid: positionID, beFailed: false)
    Test.assert(equalWithinVariance(intTargetHealth, actualHealthBeforePriceIncrease),
        message: "Expected health to be \(intTargetHealth), but got \(actualHealthBeforePriceIncrease)")

    let priceDecrease = 0.25
    let newPrice = flowStartPrice * (1.0 - priceDecrease)

    let newCollateralValue = positionFundingAmount * newPrice
    let newEffectiveCollateralValue = newCollateralValue * flowCollateralFactor
    let expectedAvailableAboveTarget = newEffectiveCollateralValue / targetHealth * flowBorrowFactor

    setMockOraclePrice(signer: protocolAccount,
        forTokenIdentifier: flowTokenIdentifier,
        price: newPrice
    )
    let actualHealthAfterPriceDecrease = getPositionHealth(pid: positionID, beFailed: false)
    // calculate new health based on updated collateral value - should increase proportionally to price increase
    let expectedHealthAfterPriceDecrease = actualHealthBeforePriceIncrease * UFix128(1.0 - priceDecrease)
    Test.assertEqual(expectedHealthAfterPriceDecrease, actualHealthAfterPriceDecrease)

    log("[TEST] FLOW price set to \(newPrice) from \(flowStartPrice)")
    log("[TEST] Position health after price decrease: \(actualHealthAfterPriceDecrease)")
    log("[TEST] Expected available above target health: \(expectedAvailableAboveTarget) MOET")

    let amounts: [UFix64] = [0.0, 10.0, 100.0, 1_000.0]

    let internalSnapshot = getCurrentBlockHeight()
    for i, amount in amounts {
        // minting to topUpSource Vault which should *not* affect calculation
        let mintToSource = amount < 100.0 ? 100.0 : amount * 10.0
        log("[TEST] Minting \(mintToSource) to position topUpSource and running again")
        mintMoet(signer: protocolAccount, to: userAccount.address, amount: mintToSource, beFailed: false)
        runFundsRequiredForTargetHealthAfterWithdrawing(
            pid: positionID,
            existingFLOWCollateral: positionFundingAmount,
            existingBorrowed: startingDebt,
            currentFLOWPrice: newPrice,
            depositIdentifier: flowTokenIdentifier,
            withdrawIdentifier: moetTokenIdentifier,
            withdrawAmount: amount
        )

        Test.reset(to: internalSnapshot)
    }

    log("==============================")
}

// TODO
// - Test deposit & withdraw same type
// - Test depositing withdraw type without pushing to sink, creating a Credit balance before testing

/* --- Parameterized runner --- */

access(all)
fun runFundsRequiredForTargetHealthAfterWithdrawing(
    pid: UInt64,
    existingFLOWCollateral: UFix64,
    existingBorrowed: UFix64,
    currentFLOWPrice: UFix64,
    depositIdentifier: String,
    withdrawIdentifier: String,
    withdrawAmount: UFix64,
) {
    log("..............................")

    let intFLOWCollateralFactor = UFix128(flowCollateralFactor)
    let intFLOWBorrowFactor = UFix128(flowBorrowFactor)
    let intFLOWPrice = UFix128(currentFLOWPrice)
    let intFLOWCollateral = UFix128(existingFLOWCollateral)
    let intFLOWBorrowed = UFix128(existingBorrowed)
    let intWithdrawAmount = UFix128(withdrawAmount)

    // effectiveCollateralValue = collateralBalance * collateralPrice * collateralFactor
    let effectiveFLOWCollateralValue = (intFLOWCollateral * intFLOWPrice) * intFLOWCollateralFactor
    // borrowLimit = (effectiveCollateralValue / targetHealth) * borrowFactor
    let expectedBorrowCapacity = (effectiveFLOWCollateralValue / intTargetHealth) * intFLOWBorrowFactor
    let desiredFinalDebt = intFLOWBorrowed + intWithdrawAmount

    var expectedRequired: UFix128 = 0.0
    if desiredFinalDebt > expectedBorrowCapacity {
        let valueDiff = desiredFinalDebt - expectedBorrowCapacity
        expectedRequired = (valueDiff * intTargetHealth) / intFLOWPrice
        expectedRequired = expectedRequired / intFLOWCollateralFactor
    }
    let ufixExpectedRequired = FlowCreditMarketMath.toUFix64Round(expectedRequired)

    log("[TEST] existingFLOWCollateral: \(existingFLOWCollateral)")
    log("[TEST] existingBorrowed: \(existingBorrowed)")
    log("[TEST] desiredFinalDebt: \(desiredFinalDebt)")
    log("[TEST] existingFLOWCollateral: \(existingFLOWCollateral)")

    let actualRequired = fundsRequiredForTargetHealthAfterWithdrawing(
            pid: pid,
            depositType: depositIdentifier,
            targetHealth: intTargetHealth,
            withdrawType: withdrawIdentifier,
            withdrawAmount: withdrawAmount,
            beFailed: false
        )
    log("[TEST] Withdraw type: \(withdrawIdentifier)")
    log("[TEST] Deposit type: \(depositIdentifier)")
    log("[TEST] Withdrawing: \(withdrawAmount)")
    log("[TEST] Expected Required: \(ufixExpectedRequired)")
    log("[TEST] Actual Required: \(actualRequired)")
    Test.assert(equalWithinVariance(ufixExpectedRequired, actualRequired),
        message: "Expected required funds to be \(ufixExpectedRequired), but got \(actualRequired)")
}
