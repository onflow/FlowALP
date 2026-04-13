import Test
import BlockchainHelpers

import "MOET"
import "test_helpers.cdc"

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()

    snapshot = getCurrentBlockHeight()
}

access(all)
fun testRebalanceUndercollateralised() {
    // Test.reset(to: snapshot)
    let initialPrice = 1.0
    let priceDropPct: UFix64 = 0.2
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: initialPrice)

    // pool + token support
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // user setup
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    let mintRes = mintFlow(to: user, amount: 1_000.0)
    Test.expect(mintRes, Test.beSucceeded())

    // Grant beta access to user so they can create positions
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // open position
    let openRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [1_000.0, FLOW_VAULT_STORAGE_PATH, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    let healthBefore = getPositionHealth(pid: 0, beFailed: false)

    // Capture available balance before price change so we can verify directionality.
    let availableBeforePriceChange = getAvailableBalance(pid: 0, vaultIdentifier: MOET_TOKEN_IDENTIFIER, pullFromTopUpSource: true, beFailed: false)

    // Apply price drop.
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: initialPrice * (1.0 - priceDropPct))

    let availableAfterPriceChange = getAvailableBalance(pid: 0, vaultIdentifier: MOET_TOKEN_IDENTIFIER, pullFromTopUpSource: true, beFailed: false)

    // After a price drop, the position becomes less healthy so the amount that is safely withdrawable should drop.
    Test.assert(availableAfterPriceChange < availableBeforePriceChange, message: "Expected available balance to decrease after price drop (before: \(availableBeforePriceChange.toString()), after: \(availableAfterPriceChange.toString()))")

    // Record the user's MOET balance before any pay-down so we can verify that the protocol actually
    // pulled the funds from the user during rebalance.
    let userMoetBalanceBefore = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    let healthAfterPriceChange = getPositionHealth(pid: 0, beFailed: false)

    let rebalanceRes = rebalancePosition(signer: PROTOCOL_ACCOUNT, pid: 0, force: true)
    Test.expect(rebalanceRes,  Test.beSucceeded())

    let healthAfterRebalance = getPositionHealth(pid: 0, beFailed: false)

    Test.assert(healthBefore > healthAfterPriceChange) // health decreased after drop
    Test.assert(healthAfterRebalance > healthAfterPriceChange) // health improved after rebalance

    let detailsAfterRebalance = getPositionDetails(pid: 0, beFailed: false)

    // Expected debt after rebalance calculation based on contract's pay-down math
    let effectiveCollateralAfterDrop = 1_000.0 * 0.8 * (1.0 - priceDropPct) // 640
    let debtBefore = 615.38461538
    let healthAfterPriceChangeVal = healthAfterPriceChange

    // Calculate required pay-down to restore health to target (1.3)
    // Formula derived from: health = effectiveCollateral / effectiveDebt
    // Solving for the debt reduction needed to achieve target health
	let requiredPaydown: UFix64 = debtBefore - effectiveCollateralAfterDrop / TARGET_HEALTH
    let expectedDebt: UFix64 = debtBefore - requiredPaydown

    var actualDebt: UFix64 = 0.0
    for bal in detailsAfterRebalance.balances {
        if bal.vaultType.identifier == MOET_TOKEN_IDENTIFIER && bal.balance > 0.0 {
            actualDebt = bal.balance
        }
    }

    let tolerance= 0.5
    Test.assert(equalWithinVariance(expectedDebt, actualDebt, tolerance))

    // Ensure the user's MOET Vault balance decreased by roughly requiredPaydown.
    let userMoetBalanceAfter = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    let paidDown = userMoetBalanceBefore - userMoetBalanceAfter
    Test.assert(
        equalWithinVariance(paidDown, requiredPaydown, tolerance),
        message: "User should have contributed ~ \(requiredPaydown.toString()) MOET toward pay-down but actually contributed \(paidDown.toString())"
    )

    log("Health after price change: \(healthAfterPriceChange.toString())")
    log("Required paydown: \(requiredPaydown.toString())")
    log("Expected debt: \(expectedDebt.toString())")
    log("Actual debt: \(actualDebt.toString())")

    // Ensure health is at least the minimum threshold (1.1)
    Test.assert(healthAfterRebalance >= INT_MIN_HEALTH,
        message: "Health after rebalance should be at least the minimum \(INT_MIN_HEALTH) but was \(healthAfterRebalance.toString())")
}

/// Verifies that rebalancing panics when the topUpSource cannot supply enough funds to
/// bring health to ≥ 1.0. Without the fix, the protocol would deposit the insufficient
/// amount into the doomed position, trapping the user's backup funds for liquidators.
access(all)
fun testRebalanceUndercollateralised_InsufficientTopUpSource() {
    Test.reset(to: snapshot)

    let initialPrice = 1.0
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: initialPrice)

    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    let mintRes = mintFlow(to: user, amount: 1_000.0)
    Test.expect(mintRes, Test.beSucceeded())
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    // Open position: user deposits 1000 FLOW, receives ~615 MOET in their vault (topUpSource).
    let openRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [1_000.0, FLOW_VAULT_STORAGE_PATH, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // Drain nearly all MOET from the user's vault, leaving only 5.0.
    // The topUpSource now holds far less than the ~215 MOET needed to restore health to 1.0
    // after the price crash below.
    let receiver = Test.createAccount()
    setupMoetVault(receiver, beFailed: false)
    let userMoetBalance = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    transferFungibleTokens(
        tokenIdentifier: MOET_TOKEN_IDENTIFIER,
        from: user,
        to: receiver,
        amount: userMoetBalance - 5.0
    )

    // Crash the price by 50% so health falls well below 1.0.
    // Effective collateral: 1000 * 0.5 * 0.8 = 400; debt ~615 → health ≈ 0.65.
    // Restoring to health 1.0 requires ~215 MOET; the source has only 5.
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: initialPrice * 0.5)

    Test.assert(getPositionHealth(pid: 0, beFailed: false) < 1.0,
        message: "Position should be liquidatable after price crash")

    // Rebalance must panic: depositing 5 MOET cannot rescue the position.
    let rebalanceRes = rebalancePosition(signer: PROTOCOL_ACCOUNT, pid: 0, force: true)
    Test.expect(rebalanceRes, Test.beFailed())
    Test.assertError(rebalanceRes, errorMessage: "topUpSource insufficient to save position from liquidation")
}