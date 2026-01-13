import Test
import BlockchainHelpers
import "test_helpers.cdc"
import "FlowCreditMarket"
import "MOET"
import "MockYieldToken"
import "FlowToken"
import "FlowCreditMarketMath"

access(all) let flowTokenIdentifier = "A.0000000000000003.FlowToken.Vault"
access(all) let moetIdentifier = "A.0000000000000007.MOET.Vault"
access(all) let mockYieldTokenIdentifier = "A.0000000000000007.MockYieldToken.Vault"
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
    createWrappedPosition(signer: user, amount: 1000.0, vaultStoragePath: /storage/flowTokenVault, pushToDrawDownSink: true)

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
    createWrappedPosition(signer: user, amount: 1000.0, vaultStoragePath: /storage/flowTokenVault, pushToDrawDownSink: true)

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
    createWrappedPosition(signer: user, amount: 1000.0, vaultStoragePath: /storage/flowTokenVault, pushToDrawDownSink: true)

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
    createWrappedPosition(signer: user, amount: 1000.0, vaultStoragePath: /storage/flowTokenVault, pushToDrawDownSink: true)

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

/// Should be able to liquidate a position, even if liquidation reduces health, if other conditions are met.
access(all)
fun testManualLiquidation_reduceHealth() {
    safeReset()
    let pid: UInt64 = 0

    // user setup
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)

    // open wrapped position and deposit via existing helper txs
    // debt is MOET, collateral is FLOW
    createWrappedPosition(signer: user, amount: 1000.0, vaultStoragePath: /storage/flowTokenVault, pushToDrawDownSink: true)

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

    let collateralBalancePreLiq = getPositionBalance(pid: pid, vaultID: flowTokenIdentifier).balance
    let debtBalancePreLiq = getPositionBalance(pid: pid, vaultID: moetIdentifier).balance

    // execute liquidation
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    let mintRes = _executeTransaction("../transactions/moet/mint_moet.cdc", [liquidator.address, 1000.0], Test.getAccount(0x0000000000000007))
    Test.expect(mintRes, Test.beSucceeded())

    let liqBalance = getBalance(address: liquidator.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0
    log("Liquidator MOET balance after mint: \(liqBalance)")

    // Repay MOET to seize FLOW. Choose seize amount above collateral balance
    let seizeAmount = collateralBalancePreLiq - 0.01
    let repayAmount = seizeAmount * newPrice * 1.01
    let liqRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-management/manual_liquidation.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier, seizeAmount, repayAmount],
        liquidator
    )
    // Should succeed, even though we are reducing health
    Test.expect(liqRes, Test.beSucceeded())

    // Validate position balances post-liquidation
    let collateralBalanceAfterLiq = getPositionBalance(pid: pid, vaultID: flowTokenIdentifier).balance
    let debtBalanceAfterLiq = getPositionBalance(pid: pid, vaultID: moetIdentifier).balance
    Test.assert(collateralBalanceAfterLiq == collateralBalancePreLiq - seizeAmount, message: "should lose exactly seized collateral")
    Test.assert(debtBalanceAfterLiq == debtBalancePreLiq -repayAmount, message: "should lose exactly repaid debt")

    let liquidatorFlowBalance = getBalance(address: liquidator.address, vaultPublicPath: /public/flowTokenBalance) ?? 0.0
    Test.assert(liquidatorFlowBalance == seizeAmount, message: "liquidator should hold seized flow")

    // health after liquidation
    let hAfterLiq = getPositionHealth(pid: pid, beFailed: false)
    let hAfterLiqUF = FlowCreditMarketMath.toUFix64Round(hAfterLiq)
    log("[LIQ] Health after liquidation: raw=\(hAfterLiq), approx=\(hAfterLiqUF)")
    Test.assert(hAfterLiq < hAfterPrice, message: "test expects health to decrease after liquidation")
}

/// Test the case where the liquidator provides a repayment vault of the collateral type instead of debt type.
access(all)
fun testManualLiquidation_repaymentVaultCollateralType() {
    safeReset()
    let pid: UInt64 = 0

    // user setup
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)

    // open wrapped position and deposit via existing helper txs
    // debt is MOET, collateral is FLOW
    createWrappedPosition(signer: user, amount: 1000.0, vaultStoragePath: /storage/flowTokenVault, pushToDrawDownSink: true)

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

    // execute liquidation, attempting to pass in FLOW instead of MOET
    let liquidator = Test.createAccount()
    transferFlowTokens(to: liquidator, amount: 1000.0)

    // Purport to repay MOET to seize FLOW, but we will actually pass in a FLOW vault for repayment
    let repayAmount = debtBalance + 0.001
    let seizeAmount = (repayAmount / newPrice) * 0.99
    let liqRes = _executeTransaction(
        "../tests/transactions/flow-credit-market/pool-management/manual_liquidation_chosen_vault.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier, flowTokenIdentifier, seizeAmount, repayAmount],
        liquidator
    )
    // Should fail because we are passing in a repayment vault with the wrong type
    Test.expect(liqRes, Test.beFailed())
    Test.assertError(liqRes, errorMessage: "Repayment vault does not match debt type")
}


/// Test the case where the liquidator provides a repayment vault with different type than the debt type.
access(all)
fun testManualLiquidation_repaymentVaultTypeMismatch() {
    safeReset()
    let pid: UInt64 = 0

    // user setup
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)

    // open wrapped position and deposit via existing helper txs
    // debt is MOET, collateral is FLOW
    createWrappedPosition(signer: user, amount: 1000.0, vaultStoragePath: /storage/flowTokenVault, pushToDrawDownSink: true)

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

    // execute liquidation, attempting to pass in MockYieldToken instead of MOET
    let liquidator = Test.createAccount()
    setupMockYieldTokenVault(liquidator, beFailed: false)
    mintMockYieldToken(signer: Test.getAccount(0x0000000000000007), to: liquidator.address, amount: 1000.0, beFailed: false)

    let liqBalance = getBalance(address: liquidator.address, vaultPublicPath: MockYieldToken.VaultPublicPath) ?? 0.0
    log("Liquidator mock balance after mint: \(liqBalance)")

    // Purport to repay MOET to seize FLOW, but we will actually pass in a MockYieldToken vault for repayment
    let repayAmount = debtBalance + 0.001
    let seizeAmount = (repayAmount / newPrice) * 0.99
    let liqRes = _executeTransaction(
        "../tests/transactions/flow-credit-market/pool-management/manual_liquidation_chosen_vault.cdc",
        [pid, Type<@MOET.Vault>().identifier, mockYieldTokenIdentifier, flowTokenIdentifier, seizeAmount, repayAmount],
        liquidator
    )
    // Should fail because we are passing in a repayment vault with the wrong type
    Test.expect(liqRes, Test.beFailed())
    Test.assertError(liqRes, errorMessage: "Repayment vault does not match debt type")
}

// Test the case where a liquidator provides repayment in an unsupported debt type.
access(all)
fun testManualLiquidation_unsupportedDebtType() {
    safeReset()
    let pid: UInt64 = 0

    // user setup
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)

    // open wrapped position and deposit via existing helper txs
    // debt is MOET, collateral is FLOW
    createWrappedPosition(signer: user, amount: 1000.0, vaultStoragePath: /storage/flowTokenVault, pushToDrawDownSink: true)

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

    // execute liquidation, attempting to pass in MockYieldToken instead of MOET
    let liquidator = Test.createAccount()
    setupMockYieldTokenVault(liquidator, beFailed: false)
    mintMockYieldToken(signer: Test.getAccount(0x0000000000000007), to: liquidator.address, amount: 1000.0, beFailed: false)

    let liqBalance = getBalance(address: liquidator.address, vaultPublicPath: MockYieldToken.VaultPublicPath) ?? 0.0
    log("Liquidator mock balance after mint: \(liqBalance)")

    // Pass in MockYieldToken as repayment, an unsupported debt type
    let repayAmount = debtBalance + 0.001
    let seizeAmount = (repayAmount / newPrice) * 0.99
    let liqRes = _executeTransaction(
        "../tests/transactions/flow-credit-market/pool-management/manual_liquidation_chosen_vault.cdc",
        [pid, mockYieldTokenIdentifier, mockYieldTokenIdentifier, flowTokenIdentifier, seizeAmount, repayAmount],
        liquidator
    )
    // Should fail because we are passing in a repayment vault with the wrong type
    Test.expect(liqRes, Test.beFailed())
    Test.assertError(liqRes, errorMessage: "Debt token type unsupported")
}

/// Test the case where a liquidator specifies an unsupported collateral type
access(all)
fun testManualLiquidation_unsupportedCollateralType() {
    safeReset()
    let pid: UInt64 = 0

    // user setup
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)

    // open wrapped position and deposit via existing helper txs
    // debt is MOET, collateral is FLOW
    createWrappedPosition(signer: user, amount: 1000.0, vaultStoragePath: /storage/flowTokenVault, pushToDrawDownSink: true)

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

    let collateralBalancePreLiq = getPositionBalance(pid: pid, vaultID: flowTokenIdentifier).balance
    let debtBalancePreLiq = getPositionBalance(pid: pid, vaultID: moetIdentifier).balance

    // execute liquidation
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    setupMockYieldTokenVault(liquidator, beFailed: false)
    let mintRes = _executeTransaction("../transactions/moet/mint_moet.cdc", [liquidator.address, 1000.0], Test.getAccount(0x0000000000000007))
    Test.expect(mintRes, Test.beSucceeded())

    let liqBalance = getBalance(address: liquidator.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0
    log("Liquidator MOET balance after mint: \(liqBalance)")

    // Repay MOET to seize FLOW. Choose seize amount above collateral balance
    let seizeAmount = collateralBalancePreLiq - 0.01
    let repayAmount = seizeAmount * newPrice * 1.01
    let liqRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-management/manual_liquidation.cdc",
        [pid, Type<@MOET.Vault>().identifier, mockYieldTokenIdentifier, seizeAmount, repayAmount],
        liquidator
    )
    // Should fail because we are specifying an unsupported collateral type (yield token)
    Test.expect(liqRes, Test.beFailed())
    Test.assertError(liqRes, errorMessage: "Collateral token type unsupported")
}

/// A liquidator specifies a supported collateral type to seize, for an unhealthy position, but the position
/// does not have a collateral balance of the specified type.
access(all)
fun testManualLiquidation_supportedDebtTypeNotInPosition() {
    safeReset()
    let protocolAccount = Test.getAccount(0x0000000000000007)

    // Add MockYieldToken as a supported token type
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: mockYieldTokenIdentifier, price: 1.0)
    addSupportedTokenZeroRateCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: mockYieldTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // user1 setup - deposits FLOW
    let user1 = Test.createAccount()
    setupMoetVault(user1, beFailed: false)
    transferFlowTokens(to: user1, amount: 1000.0)

    // user1 opens wrapped position with FLOW collateral
    // debt is MOET, collateral is FLOW
    let pid1: UInt64 = 0
    createWrappedPosition(signer: user1, amount: 1000.0, vaultStoragePath: /storage/flowTokenVault, pushToDrawDownSink: true)

    // user2 setup - deposits MockYieldToken
    let user2 = Test.createAccount()
    setupMoetVault(user2, beFailed: false)
    setupMockYieldTokenVault(user2, beFailed: false)
    mintMockYieldToken(signer: protocolAccount, to: user2.address, amount: 1000.0, beFailed: false)

    // user2 opens wrapped position with MockYieldToken collateral
    let pid2: UInt64 = 1
    createWrappedPosition(signer: user2, amount: 1000.0, vaultStoragePath: MockYieldToken.VaultStoragePath, pushToDrawDownSink: true)

    // health before price drop for user1
    let hBefore = getPositionHealth(pid: pid1, beFailed: false)
    let hBeforeUF = FlowCreditMarketMath.toUFix64Round(hBefore)
    log("[LIQ] User1 health before price drop: raw=\(hBefore), approx=\(hBeforeUF)")

    // cause undercollateralization for user1 by dropping FLOW price
    let newPrice = 0.7 // $/FLOW
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: newPrice)
    let hAfterPrice = getPositionHealth(pid: pid1, beFailed: false)
    let hAfterPriceUF = FlowCreditMarketMath.toUFix64Round(hAfterPrice)
    log("[LIQ] User1 health after price drop: raw=\(hAfterPrice), approx=\(hAfterPriceUF)")

    // execute liquidation
    let liquidator = Test.createAccount()
    setupMockYieldTokenVault(liquidator, beFailed: false)
    mintMockYieldToken(signer: protocolAccount, to: liquidator.address, amount: 1000.0, beFailed: false)

    let liqBalance = getBalance(address: liquidator.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0
    log("Liquidator MOET balance after mint: \(liqBalance)")

    // Try to liquidate user1's position but repay MockYieldToken instead of MOET
    // user1 has no MockYieldToken debt balance 
    let seizeAmount = 0.01
    let repayAmount = 100.0
    let liqRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-management/manual_liquidation.cdc",
        [pid1, mockYieldTokenIdentifier, flowTokenIdentifier, seizeAmount, repayAmount],
        liquidator
    )
    // Should fail because user1's position doesn't have MockYieldToken collateral
    Test.expect(liqRes, Test.beFailed())
    Test.assertError(liqRes, errorMessage: "Cannot repay more debt than is in position")
}

/// A liquidator specifies a supported debt type to repay, for an unhealthy position, but the position
/// does not have a debt balance of the specified type.
access(all)
fun testManualLiquidation_supportedCollateralTypeNotInPosition() {
    safeReset()
    let protocolAccount = Test.getAccount(0x0000000000000007)

    // Add MockYieldToken as a supported token (can be used as collateral or debt)
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: mockYieldTokenIdentifier, price: 1.0)
    addSupportedTokenZeroRateCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: mockYieldTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // user1 setup - deposits FLOW, borrows MOET
    let user1 = Test.createAccount()
    setupMoetVault(user1, beFailed: false)
    transferFlowTokens(to: user1, amount: 1000.0)

    // user1 opens wrapped position with FLOW collateral, MOET debt
    let pid1: UInt64 = 0
    createWrappedPosition(signer: user1, amount: 1000.0, vaultStoragePath: /storage/flowTokenVault, pushToDrawDownSink: true)

    // user2 setup - deposits MockYieldToken, borrows MOET
    let user2 = Test.createAccount()
    setupMoetVault(user2, beFailed: false)
    setupMockYieldTokenVault(user2, beFailed: false)
    mintMockYieldToken(signer: protocolAccount, to: user2.address, amount: 1000.0, beFailed: false)

    // user2 opens wrapped position with MockYieldToken collateral
    let pid2: UInt64 = 1
    createWrappedPosition(signer: user2, amount: 1000.0, vaultStoragePath: MockYieldToken.VaultStoragePath, pushToDrawDownSink: true)

    // health before price drop for user1
    let hBefore = getPositionHealth(pid: pid1, beFailed: false)
    let hBeforeUF = FlowCreditMarketMath.toUFix64Round(hBefore)
    log("[LIQ] User1 health before price drop: raw=\(hBefore), approx=\(hBeforeUF)")

    // cause undercollateralization for user1 by dropping FLOW price
    let newPrice = 0.5 // $/FLOW
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: newPrice)
    let hAfterPrice = getPositionHealth(pid: pid1, beFailed: false)
    let hAfterPriceUF = FlowCreditMarketMath.toUFix64Round(hAfterPrice)
    log("[LIQ] User1 health after price drop: raw=\(hAfterPrice), approx=\(hAfterPriceUF)")

    // execute liquidation
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    setupMockYieldTokenVault(liquidator, beFailed: false)
    mintMoet(signer: protocolAccount, to: liquidator.address, amount: 1000.0, beFailed: false)

    let liqBalance = getBalance(address: liquidator.address, vaultPublicPath: MockYieldToken.VaultPublicPath) ?? 0.0
    log("Liquidator MockYieldToken balance after mint: \(liqBalance)")

    // Try to liquidate user1's position by repaying MockYieldToken debt
    // User1 only has MOET debt, not MockYieldToken debt
    let seizeAmount = 0.01
    let repayAmount = 100.0
    let liqRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-management/manual_liquidation.cdc",
        [pid1, Type<@MOET.Vault>().identifier, mockYieldTokenIdentifier, seizeAmount, repayAmount],
        liquidator
    )
    // Should fail because user1's position doesn't have MockYieldToken debt
    Test.expect(liqRes, Test.beFailed())
    log(liqRes.error)
    Test.assertError(liqRes, errorMessage: "Cannot seize more collateral than is in position")
}

/// All liquidations should fail when liquidations are paused.
access(all)
fun testManualLiquidation_liquidationPaused() {}

/// All liquidations should fail during warmup period following liquidation pause.
access(all)
fun testManualLiquidation_liquidationWarmup() {}

/// Liquidations should fail if DEX price and oracle price diverge by too much.
access(all)
fun testManualLiquidation_dexOraclePriceDivergence() {}

/// Should be able to liquidate to below target health while increasing health factor.
access(all)
fun testManualLiquidation_increaseHealthBelowTarget() {}

/// Should be able to liquidate to exactly target health
access(all)
fun testManualLiquidation_liquidateToTarget() {}

