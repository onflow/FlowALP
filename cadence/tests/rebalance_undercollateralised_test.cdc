import Test
import BlockchainHelpers

import "MOET"
import "test_helpers.cdc"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) let protocolConsumerAccount = Test.getAccount(0x0000000000000008)
access(all) var snapshot: UInt64 = 0

access(all) let flowTokenIdentifier = "A.0000000000000003.FlowToken.Vault"
access(all) let flowVaultStoragePath = /storage/flowTokenVault

access(all)
fun setup() {
    deployContracts()

    let betaTxResult = grantBeta(protocolAccount, protocolConsumerAccount)

    Test.expect(betaTxResult, Test.beSucceeded())

    snapshot = getCurrentBlockHeight()
}

access(all)
fun testRebalanceUndercollateralised() {
    // Test.reset(to: snapshot)
    let initialPrice = 1.0
    let priceDropPct: UFix64 = 0.2
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: initialPrice)

    // pool + token support
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // user setup
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 1_000.0)

    // open position
    let openRes = executeTransaction(
        "./transactions/mock-flow-credit-market-consumer/create_wrapped_position.cdc",
        [1_000.0, flowVaultStoragePath, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    let healthBefore = getPositionHealth(pid: 0, beFailed: false)

    // Capture available balance before price change so we can verify directionality.
    let availableBeforePriceChange = getAvailableBalance(pid: 0, vaultIdentifier: defaultTokenIdentifier, pullFromTopUpSource: true, beFailed: false)

    // Apply price drop.
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: initialPrice * (1.0 - priceDropPct))

    let availableAfterPriceChange = getAvailableBalance(pid: 0, vaultIdentifier: defaultTokenIdentifier, pullFromTopUpSource: true, beFailed: false)

    // After a price drop, the position becomes less healthy so the amount that is safely withdrawable should drop.
    Test.assert(availableAfterPriceChange < availableBeforePriceChange, message: "Expected available balance to decrease after price drop (before: ".concat(availableBeforePriceChange.toString()).concat(", after: ").concat(availableAfterPriceChange.toString()).concat(")"))

    // Record the user's MOET balance before any pay-down so we can verify that the protocol actually
    // pulled the funds from the user during rebalance.
    let userMoetBalanceBefore = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    let healthAfterPriceChange = getPositionHealth(pid: 0, beFailed: false)

    rebalancePosition(signer: protocolAccount, pid: 0, force: true, beFailed: false)

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
	let requiredPaydown: UFix64 = debtBefore - effectiveCollateralAfterDrop / targetHealth
    let expectedDebt: UFix64 = debtBefore - requiredPaydown

    var actualDebt: UFix64 = 0.0
    for bal in detailsAfterRebalance.balances {
        if bal.vaultType.identifier == defaultTokenIdentifier && bal.balance > 0.0 {
            actualDebt = bal.balance
        }
    }

    let tolerance: UFix64 = 0.5
    Test.assert((actualDebt >= expectedDebt - tolerance) && (actualDebt <= expectedDebt + tolerance))

    // Ensure the user's MOET Vault balance decreased by roughly requiredPaydown.
    let userMoetBalanceAfter = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    let paidDown = userMoetBalanceBefore - userMoetBalanceAfter
    Test.assert(paidDown >= requiredPaydown - tolerance && paidDown <= requiredPaydown + tolerance,
        message: "User should have contributed ~".concat(requiredPaydown.toString()).concat(" MOET toward pay-down but actually contributed ").concat(paidDown.toString()))

    log("Health after price change: ".concat(healthAfterPriceChange.toString()))
    log("Required paydown: ".concat(requiredPaydown.toString()))
    log("Expected debt: ".concat(expectedDebt.toString()))
    log("Actual debt: ".concat(actualDebt.toString()))

    // Ensure health is at least the minimum threshold (1.1)
    Test.assert(healthAfterRebalance >= intMinHealth,
        message: "Health after rebalance should be at least the minimum \(intMinHealth) but was ".concat(healthAfterRebalance.toString()))
} 
