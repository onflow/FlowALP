import Test
import BlockchainHelpers
import "test_helpers.cdc"
import "FlowCreditMarket"
import "MOET"
import "FlowToken"
import "FlowCreditMarketMath"

access(all) let flowTokenIdentifier = "A.0000000000000003.FlowToken.Vault"
access(all) let moetIdentifier = "A.0000000000000007.MOET.Vault"
access(all) var snapshot: UInt64 = 0

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

    let protocolAccount = Test.getAccount(0x0000000000000007)

    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)
    grantPoolCapToConsumer()
    addSupportedTokenZeroRateCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    snapshot = getCurrentBlockHeight()
}

/// Should be unable to liquidate healthy position.
access(all)
fun testManualLiquidation_healthyPosition() {
    safeReset()
    let pid: UInt64 = 0

    // user setup
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)

    // open wrapped position and deposit via existing helper txs
    // debt is MOET, collateral is FLOW
    let openRes = _executeTransaction(
        "./transactions/mock-flow-credit-market-consumer/create_wrapped_position.cdc",
        [1000.0, /storage/flowTokenVault, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // Log initial health
    let hBefore = getPositionHealth(pid: pid, beFailed: false)
    let hBeforeUF = FlowCreditMarketMath.toUFix64Round(hBefore)
    log("[LIQ] Health before price drop: raw=\(hBefore), approx=\(hBeforeUF)")
    Test.assert(hBefore >= 1.0, message: "initial position state is unhealthy")

    // execute liquidation
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    let mintRes = _executeTransaction("../transactions/moet/mint_moet.cdc", [liquidator.address, 1000.0], Test.getAccount(0x0000000000000007))
    Test.expect(mintRes, Test.beSucceeded())

    let liqBalance = getBalance(address: liquidator.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0
    log("Liquidator MOET balance after mint: \(liqBalance)")

    // Repay MOET to seize FLOW
    let repayAmount = 2.0
    let seizeAmount = 1.0
    let liqRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-management/manual_liquidation.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier, seizeAmount, repayAmount],
        liquidator
    )
    Test.expect(liqRes, Test.beFailed())
    Test.assertError(liqRes, errorMessage: "Cannot liquidate healthy position")
}

/// Should be unable to liquidate a position to above target health.
access(all)
fun testManualLiquidation_liquidationExceedsTargetHealth() {
    safeReset()
    let pid: UInt64 = 0

    // user setup
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)

    // open wrapped position and deposit via existing helper txs
    // debt is MOET, collateral is FLOW
    let openRes = _executeTransaction(
        "./transactions/mock-flow-credit-market-consumer/create_wrapped_position.cdc",
        [1000.0, /storage/flowTokenVault, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // health before price drop
    let hBefore = getPositionHealth(pid: pid, beFailed: false)
    let hBeforeUF = FlowCreditMarketMath.toUFix64Round(hBefore)
    log("[LIQ] Health before price drop: raw=\(hBefore), approx=\(hBeforeUF)")

    // cause undercollateralization
    let newPrice = 0.7 // $/FLOW
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: flowTokenIdentifier, price: newPrice)
    let hAfterPrice = getPositionHealth(pid: pid, beFailed: false)
    let hAfterPriceUF = FlowCreditMarketMath.toUFix64Round(hAfterPrice)
    log("[LIQ] Health after price drop: raw=\(hAfterPrice), approx=\(hAfterPriceUF)")

    // execute liquidation
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    let mintRes = _executeTransaction("../transactions/moet/mint_moet.cdc", [liquidator.address, 1000.0], Test.getAccount(0x0000000000000007))
    Test.expect(mintRes, Test.beSucceeded())

    let liqBalance = getBalance(address: liquidator.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0
    log("Liquidator MOET balance after mint: \(liqBalance)")

    // Repay MOET to seize FLOW.
    // TODO(jord): add helper to compute health boundaries given best acceptable price, then test boundaries
    let repayAmount = 500.0
    let seizeAmount = 500.0
    let liqRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-management/manual_liquidation.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier, seizeAmount, repayAmount],
        liquidator
    )
    // Should fail because we are repaying/seizing too much
    Test.expect(liqRes, Test.beFailed())
    Test.assertError(liqRes, errorMessage: "Liquidation must not exceed target health")

    // health after liquidation
    let hAfterLiq = getPositionHealth(pid: pid, beFailed: false)
    let hAfterLiqUF = FlowCreditMarketMath.toUFix64Round(hAfterLiq)
    log("[LIQ] Health after liquidation: raw=\(hAfterLiq), approx=\(hAfterLiqUF)")

    Test.assert(hAfterLiq == hAfterPrice, message: "sanity check: health should not change after failed liquidation")
}

/// Should be unable to liquidate a position by repaying more debt than the position holds.
access(all)
fun testManualLiquidation_repayExceedsDebt() {
    safeReset()
    let pid: UInt64 = 0

    // user setup
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)

    // open wrapped position and deposit via existing helper txs
    // debt is MOET, collateral is FLOW
    let openRes = _executeTransaction(
        "./transactions/mock-flow-credit-market-consumer/create_wrapped_position.cdc",
        [1000.0, /storage/flowTokenVault, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // health before price drop
    let hBefore = getPositionHealth(pid: pid, beFailed: false)
    let hBeforeUF = FlowCreditMarketMath.toUFix64Round(hBefore)
    log("[LIQ] Health before price drop: raw=\(hBefore), approx=\(hBeforeUF)")

    // cause undercollateralization
    let newPrice = 0.7 // $/FLOW
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: flowTokenIdentifier, price: newPrice)
    let hAfterPrice = getPositionHealth(pid: pid, beFailed: false)
    let hAfterPriceUF = FlowCreditMarketMath.toUFix64Round(hAfterPrice)
    log("[LIQ] Health after price drop: raw=\(hAfterPrice), approx=\(hAfterPriceUF)")

    let debtPositionBalance = getPositionBalance(pid: pid, vaultID: moetIdentifier)
    Test.assert(debtPositionBalance.direction == FlowCreditMarket.BalanceDirection.Debit)
    var debtBalance = debtPositionBalance.balance

    // execute liquidation
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    let mintRes = _executeTransaction("../transactions/moet/mint_moet.cdc", [liquidator.address, 1000.0], Test.getAccount(0x0000000000000007))
    Test.expect(mintRes, Test.beSucceeded())

    let liqBalance = getBalance(address: liquidator.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0
    log("Liquidator MOET balance after mint: \(liqBalance)")

    // Repay MOET to seize FLOW. Choose repay amount above debt balance
    let repayAmount = debtBalance + 0.001
    let seizeAmount = (repayAmount / newPrice) * 0.99
    let liqRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-management/manual_liquidation.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier, seizeAmount, repayAmount],
        liquidator
    )
    // Should fail because we are repaying too much
    Test.expect(liqRes, Test.beFailed())
    Test.assertError(liqRes, errorMessage: "Cannot repay more debt than is in position")

    // health after liquidation
    let hAfterLiq = getPositionHealth(pid: pid, beFailed: false)
    let hAfterLiqUF = FlowCreditMarketMath.toUFix64Round(hAfterLiq)
    log("[LIQ] Health after liquidation: raw=\(hAfterLiq), approx=\(hAfterLiqUF)")

    Test.assert(hAfterLiq == hAfterPrice, message: "sanity check: health should not change after failed liquidation")
}

/// Should be unable to liquidate a position by seizing more collateral than the position holds.
access(all)
fun testManualLiquidation_seizeExceedsCollateral() {
    safeReset()
    let pid: UInt64 = 0

    // user setup
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)

    // open wrapped position and deposit via existing helper txs
    // debt is MOET, collateral is FLOW
    let openRes = _executeTransaction(
        "./transactions/mock-flow-credit-market-consumer/create_wrapped_position.cdc",
        [1000.0, /storage/flowTokenVault, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // health before price drop
    let hBefore = getPositionHealth(pid: pid, beFailed: false)
    let hBeforeUF = FlowCreditMarketMath.toUFix64Round(hBefore)
    log("[LIQ] Health before price drop: raw=\(hBefore), approx=\(hBeforeUF)")

    // cause undercollateralization AND insolvency
    let newPrice = 0.5 // $/FLOW
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: flowTokenIdentifier, price: newPrice)
    let hAfterPrice = getPositionHealth(pid: pid, beFailed: false)
    let hAfterPriceUF = FlowCreditMarketMath.toUFix64Round(hAfterPrice)
    log("[LIQ] Health after price drop: raw=\(hAfterPrice), approx=\(hAfterPriceUF)")

    let collateralBalance = getPositionBalance(pid: pid, vaultID: flowTokenIdentifier).balance

    // execute liquidation
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    let mintRes = _executeTransaction("../transactions/moet/mint_moet.cdc", [liquidator.address, 1000.0], Test.getAccount(0x0000000000000007))
    Test.expect(mintRes, Test.beSucceeded())

    let liqBalance = getBalance(address: liquidator.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0
    log("Liquidator MOET balance after mint: \(liqBalance)")

    // Repay MOET to seize FLOW. Choose seize amount above collateral balance
    let seizeAmount = collateralBalance + 0.001
    let repayAmount = seizeAmount * newPrice * 1.01
    let liqRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-management/manual_liquidation.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier, seizeAmount, repayAmount],
        liquidator
    )
    // Should fail because we are seizing too much collateral
    Test.expect(liqRes, Test.beFailed())
    Test.assertError(liqRes, errorMessage: "Cannot seize more collateral than is in position")

    // health after liquidation
    let hAfterLiq = getPositionHealth(pid: pid, beFailed: false)
    let hAfterLiqUF = FlowCreditMarketMath.toUFix64Round(hAfterLiq)
    log("[LIQ] Health after liquidation: raw=\(hAfterLiq), approx=\(hAfterLiqUF)")

    Test.assert(hAfterLiq == hAfterPrice, message: "sanity check: health should not change after failed liquidation")
}
