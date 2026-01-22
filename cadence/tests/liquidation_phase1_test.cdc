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
    // setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: moetIdentifier, price: 1.0)
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

    // Add DEX swapper for FLOW -> MOET pair (for liquidations)
    // priceRatio = 1.0 means 1 MOET per 1 FLOW (matches oracle prices)
    addMockDexSwapper(
        signer: protocolAccount,
        inVaultIdentifier: flowTokenIdentifier,
        outVaultIdentifier: moetIdentifier,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: 1.0
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
    let health = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(health >= 1.0, message: "initial position state is unhealthy")

    // execute liquidation
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    mintMoet(signer: Test.getAccount(0x0000000000000007), to: liquidator.address, amount: 1000.0, beFailed: false)

    let liqBalance = getBalance(address: liquidator.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0

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

    // cause undercollateralization
    let newPrice = 0.7 // $/FLOW
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: flowTokenIdentifier, price: newPrice)
    // Update DEX price to match oracle
    addMockDexSwapper(
        signer: Test.getAccount(0x0000000000000007),
        inVaultIdentifier: flowTokenIdentifier,
        outVaultIdentifier: moetIdentifier,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: newPrice
    )
    let hAfterPrice = getPositionHealth(pid: pid, beFailed: false)

    // execute liquidation
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    mintMoet(signer: Test.getAccount(0x0000000000000007), to: liquidator.address, amount: 1000.0, beFailed: false)

    let liqBalance = getBalance(address: liquidator.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0

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

    // cause undercollateralization
    let newPrice = 0.7 // $/FLOW
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: flowTokenIdentifier, price: newPrice)
    // Update DEX price to match oracle
    addMockDexSwapper(
        signer: Test.getAccount(0x0000000000000007),
        inVaultIdentifier: flowTokenIdentifier,
        outVaultIdentifier: moetIdentifier,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: newPrice
    )
    let hAfterPrice = getPositionHealth(pid: pid, beFailed: false)

    let debtPositionBalance = getPositionBalance(pid: pid, vaultID: moetIdentifier)
    Test.assert(debtPositionBalance.direction == FlowCreditMarket.BalanceDirection.Debit)
    var debtBalance = debtPositionBalance.balance

    // execute liquidation
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    mintMoet(signer: Test.getAccount(0x0000000000000007), to: liquidator.address, amount: 1000.0, beFailed: false)

    let liqBalance = getBalance(address: liquidator.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0

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

    // cause undercollateralization AND insolvency
    let newPrice = 0.5 // $/FLOW
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: flowTokenIdentifier, price: newPrice)
    // Update DEX price to match oracle
    addMockDexSwapper(
        signer: Test.getAccount(0x0000000000000007),
        inVaultIdentifier: flowTokenIdentifier,
        outVaultIdentifier: moetIdentifier,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: newPrice
    )
    let hAfterPrice = getPositionHealth(pid: pid, beFailed: false)

    let collateralBalance = getPositionBalance(pid: pid, vaultID: flowTokenIdentifier).balance

    // execute liquidation
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    mintMoet(signer: Test.getAccount(0x0000000000000007), to: liquidator.address, amount: 1000.0, beFailed: false)

    let liqBalance = getBalance(address: liquidator.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0

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

    // cause undercollateralization AND insolvency
    let newPrice = 0.5 // $/FLOW
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: flowTokenIdentifier, price: newPrice)
    // Update DEX price to match oracle
    addMockDexSwapper(
        signer: Test.getAccount(0x0000000000000007),
        inVaultIdentifier: flowTokenIdentifier,
        outVaultIdentifier: moetIdentifier,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: newPrice
    )
    let hAfterPrice = getPositionHealth(pid: pid, beFailed: false)

    let collateralBalancePreLiq = getPositionBalance(pid: pid, vaultID: flowTokenIdentifier).balance
    let debtBalancePreLiq = getPositionBalance(pid: pid, vaultID: moetIdentifier).balance

    // execute liquidation
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    mintMoet(signer: Test.getAccount(0x0000000000000007), to: liquidator.address, amount: 1000.0, beFailed: false)

    let liqBalance = getBalance(address: liquidator.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0

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
    Test.assert(hAfterLiq < hAfterPrice, message: "test expects health to decrease after liquidation")
}

/// Should be able to liquidate to below target health while increasing health factor.
access(all)
fun testManualLiquidation_increaseHealthBelowTarget() {
    safeReset()
    let pid: UInt64 = 0

    // user setup
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)

    // open wrapped position and deposit via existing helper txs
    // debt is MOET, collateral is FLOW
    createWrappedPosition(signer: user, amount: 1000.0, vaultStoragePath: /storage/flowTokenVault, pushToDrawDownSink: true)

    // cause severe undercollateralization
    let newPrice = 0.5 // $/FLOW
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: flowTokenIdentifier, price: newPrice)

    // Update DEX price to match oracle
    addMockDexSwapper(
        signer: Test.getAccount(0x0000000000000007),
        inVaultIdentifier: flowTokenIdentifier,
        outVaultIdentifier: moetIdentifier,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: newPrice
    )

    let healthBefore = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(healthBefore < 1.05, message: "position should be unhealthy before liquidation")

    // execute liquidation
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    mintMoet(signer: Test.getAccount(0x0000000000000007), to: liquidator.address, amount: 1000.0, beFailed: false)

    // Repay MOET to seize FLOW
    // DEX quote would require: 100/0.5 = 200 FLOW
    // Liquidator offers 150 FLOW < 200 FLOW (better price)
    let repayAmount = 100.0
    let seizeAmount = 150.0
    let liqRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-management/manual_liquidation.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier, seizeAmount, repayAmount],
        liquidator
    )
    // Should succeed
    Test.expect(liqRes, Test.beSucceeded())

    // Check post-liquidation health
    let healthAfter = getPositionHealth(pid: pid, beFailed: false)

    // Health should have improved
    Test.assert(healthAfter > healthBefore, message: "health should improve after liquidation")

    // Health should still be below target
    Test.assert(healthAfter < 1.05, message: "health should still be below target (1.05)")
}

/// Should be able to liquidate to exactly target health
access(all)
fun testManualLiquidation_liquidateToTarget() {
    safeReset()
    let pid: UInt64 = 0

    // user setup
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)

    // open wrapped position and deposit via existing helper txs
    // debt is MOET, collateral is FLOW
    createWrappedPosition(signer: user, amount: 1000.0, vaultStoragePath: /storage/flowTokenVault, pushToDrawDownSink: true)

    // cause undercollateralization
    let newPrice = 0.7 // $/FLOW
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: flowTokenIdentifier, price: newPrice)

    // Update DEX price to match oracle
    addMockDexSwapper(
        signer: Test.getAccount(0x0000000000000007),
        inVaultIdentifier: flowTokenIdentifier,
        outVaultIdentifier: moetIdentifier,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: newPrice
    )

    let healthBefore = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(healthBefore < 1.05, message: "position should be unhealthy before liquidation")

    // execute liquidation
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    mintMoet(signer: Test.getAccount(0x0000000000000007), to: liquidator.address, amount: 1000.0, beFailed: false)

    // Repay MOET to seize FLOW - calculated to bring health to exactly 1.05
    // Initial: 1000 FLOW at $0.7 with effective collateral factor 0.8
    // Debt: ~615.38 MOET (from auto-borrow at creation)
    // Pre-health: (1000 * 0.7 * 0.8) / 615.38 = 0.91
    // Target post-health: 1.05
    // Formula: (1000 - seizeAmount) * 0.7 * 0.8 / (615.38 - repayAmount) = 1.05
    // Using repayAmount = 100: seizeAmount = 33.66
    // DEX quote would require: 100/0.7 = 142.86 FLOW
    // Liquidator offers 33.66 FLOW < 142.86 FLOW (better price)
    let repayAmount = 100.0
    let seizeAmount = 33.66
    let liqRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-management/manual_liquidation.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier, seizeAmount, repayAmount],
        liquidator
    )
    // Should succeed
    Test.expect(liqRes, Test.beSucceeded())

    // Check post-liquidation health
    let healthAfter = getPositionHealth(pid: pid, beFailed: false)

    // Health should be very close to target (1.05), allowing for small variance
    Test.assert(healthAfter >= 1.04 && healthAfter <= 1.06, message: "health should be close to target (1.05), actual: ".concat(healthAfter.toString()))
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

    // cause undercollateralization
    let newPrice = 0.7 // $/FLOW
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: flowTokenIdentifier, price: newPrice)
    // Update DEX price to match oracle
    addMockDexSwapper(
        signer: Test.getAccount(0x0000000000000007),
        inVaultIdentifier: flowTokenIdentifier,
        outVaultIdentifier: moetIdentifier,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: newPrice
    )
    let hAfterPrice = getPositionHealth(pid: pid, beFailed: false)

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

    // cause undercollateralization
    let newPrice = 0.7 // $/FLOW
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: flowTokenIdentifier, price: newPrice)
    // Update DEX price to match oracle
    addMockDexSwapper(
        signer: Test.getAccount(0x0000000000000007),
        inVaultIdentifier: flowTokenIdentifier,
        outVaultIdentifier: moetIdentifier,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: newPrice
    )
    let hAfterPrice = getPositionHealth(pid: pid, beFailed: false)

    let debtPositionBalance = getPositionBalance(pid: pid, vaultID: moetIdentifier)
    Test.assert(debtPositionBalance.direction == FlowCreditMarket.BalanceDirection.Debit)
    var debtBalance = debtPositionBalance.balance

    // execute liquidation, attempting to pass in MockYieldToken instead of MOET
    let liquidator = Test.createAccount()
    setupMockYieldTokenVault(liquidator, beFailed: false)
    mintMockYieldToken(signer: Test.getAccount(0x0000000000000007), to: liquidator.address, amount: 1000.0, beFailed: false)

    let liqBalance = getBalance(address: liquidator.address, vaultPublicPath: MockYieldToken.VaultPublicPath) ?? 0.0

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

    // cause undercollateralization
    let newPrice = 0.7 // $/FLOW
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: flowTokenIdentifier, price: newPrice)
    // Update DEX price to match oracle
    addMockDexSwapper(
        signer: Test.getAccount(0x0000000000000007),
        inVaultIdentifier: flowTokenIdentifier,
        outVaultIdentifier: moetIdentifier,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: newPrice
    )
    let hAfterPrice = getPositionHealth(pid: pid, beFailed: false)

    let debtPositionBalance = getPositionBalance(pid: pid, vaultID: moetIdentifier)
    Test.assert(debtPositionBalance.direction == FlowCreditMarket.BalanceDirection.Debit)
    var debtBalance = debtPositionBalance.balance

    // execute liquidation, attempting to pass in MockYieldToken instead of MOET
    let liquidator = Test.createAccount()
    setupMockYieldTokenVault(liquidator, beFailed: false)
    mintMockYieldToken(signer: Test.getAccount(0x0000000000000007), to: liquidator.address, amount: 1000.0, beFailed: false)

    let liqBalance = getBalance(address: liquidator.address, vaultPublicPath: MockYieldToken.VaultPublicPath) ?? 0.0

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

    // cause undercollateralization
    let newPrice = 0.7 // $/FLOW
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: flowTokenIdentifier, price: newPrice)
    // Update DEX price to match oracle
    addMockDexSwapper(
        signer: Test.getAccount(0x0000000000000007),
        inVaultIdentifier: flowTokenIdentifier,
        outVaultIdentifier: moetIdentifier,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: newPrice
    )
    let hAfterPrice = getPositionHealth(pid: pid, beFailed: false)

    let collateralBalancePreLiq = getPositionBalance(pid: pid, vaultID: flowTokenIdentifier).balance
    let debtBalancePreLiq = getPositionBalance(pid: pid, vaultID: moetIdentifier).balance

    // execute liquidation
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    setupMockYieldTokenVault(liquidator, beFailed: false)
    mintMoet(signer: Test.getAccount(0x0000000000000007), to: liquidator.address, amount: 1000.0, beFailed: false)

    let liqBalance = getBalance(address: liquidator.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0

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

    // Add DEX swapper for MockYieldToken -> MOET pair
    addMockDexSwapper(
        signer: protocolAccount,
        inVaultIdentifier: mockYieldTokenIdentifier,
        outVaultIdentifier: moetIdentifier,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: 1.0
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

    // cause undercollateralization for user1 by dropping FLOW price
    let newPrice = 0.7 // $/FLOW
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: newPrice)
    // Update DEX price to match oracle
    addMockDexSwapper(
        signer: protocolAccount,
        inVaultIdentifier: flowTokenIdentifier,
        outVaultIdentifier: moetIdentifier,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: newPrice
    )
    let hAfterPrice = getPositionHealth(pid: pid1, beFailed: false)

    // execute liquidation
    let liquidator = Test.createAccount()
    setupMockYieldTokenVault(liquidator, beFailed: false)
    mintMockYieldToken(signer: protocolAccount, to: liquidator.address, amount: 1000.0, beFailed: false)

    let liqBalance = getBalance(address: liquidator.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0

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

    // Add DEX swapper for MockYieldToken -> MOET pair
    addMockDexSwapper(
        signer: protocolAccount,
        inVaultIdentifier: mockYieldTokenIdentifier,
        outVaultIdentifier: moetIdentifier,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: 1.0
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

    // cause undercollateralization for user1 by dropping FLOW price
    let newPrice = 0.5 // $/FLOW
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: newPrice)
    // Update DEX price to match oracle
    addMockDexSwapper(
        signer: protocolAccount,
        inVaultIdentifier: flowTokenIdentifier,
        outVaultIdentifier: moetIdentifier,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: newPrice
    )
    let hAfterPrice = getPositionHealth(pid: pid1, beFailed: false)

    // execute liquidation
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    setupMockYieldTokenVault(liquidator, beFailed: false)
    mintMoet(signer: protocolAccount, to: liquidator.address, amount: 1000.0, beFailed: false)

    let liqBalance = getBalance(address: liquidator.address, vaultPublicPath: MockYieldToken.VaultPublicPath) ?? 0.0

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
    Test.assertError(liqRes, errorMessage: "Cannot seize more collateral than is in position")
}

/// All liquidations should fail when liquidations are paused.
access(all)
fun testManualLiquidation_liquidationPaused() {
    safeReset()
    let pid: UInt64 = 0
    let protocolAccount = Test.getAccount(0x0000000000000007)

    // Setup: Create undercollateralized position
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)
    createWrappedPosition(
        signer: user,
        amount: 1000.0,
        vaultStoragePath: /storage/flowTokenVault,
        pushToDrawDownSink: true
    )

    // Cause undercollateralization by dropping FLOW price
    let newPrice = 0.7
    setMockOraclePrice(
        signer: protocolAccount,
        forTokenIdentifier: flowTokenIdentifier,
        price: newPrice
    )
    addMockDexSwapper(
        signer: protocolAccount,
        inVaultIdentifier: flowTokenIdentifier,
        outVaultIdentifier: moetIdentifier,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: newPrice
    )

    // Verify position is unhealthy
    let health = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(health < 1.0, message: "Position should be liquidatable")

    // PAUSE LIQUIDATIONS
    pauseLiquidations(signer: protocolAccount, flag: true)

    // Verify pause state
    let params = getLiquidationParams()
    Test.assert(
        params.paused == true,
        message: "Liquidations should be paused"
    )

    // Setup liquidator
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    mintMoet(
        signer: protocolAccount,
        to: liquidator.address,
        amount: 1000.0,
        beFailed: false
    )

    // Attempt liquidation - should fail due to pause
    let repayAmount = 2.0
    let seizeAmount = 1.0
    let liqRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-management/manual_liquidation.cdc",
        [
            pid,
            Type<@MOET.Vault>().identifier,
            flowTokenIdentifier,
            seizeAmount,
            repayAmount
        ],
        liquidator
    )

    // Assert: Liquidation should fail with pause message
    Test.expect(liqRes, Test.beFailed())
    Test.assertError(liqRes, errorMessage: "Liquidations paused")
}

/// All liquidations should fail during warmup period following liquidation pause.
access(all)
fun testManualLiquidation_liquidationWarmup() {
    safeReset()
    let pid: UInt64 = 0
    let protocolAccount = Test.getAccount(0x0000000000000007)

    // Setup: Create undercollateralized position
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)
    createWrappedPosition(
        signer: user,
        amount: 1000.0,
        vaultStoragePath: /storage/flowTokenVault,
        pushToDrawDownSink: true
    )

    // Cause undercollateralization
    let newPrice = 0.7
    setMockOraclePrice(
        signer: protocolAccount,
        forTokenIdentifier: flowTokenIdentifier,
        price: newPrice
    )
    addMockDexSwapper(
        signer: protocolAccount,
        inVaultIdentifier: flowTokenIdentifier,
        outVaultIdentifier: moetIdentifier,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: newPrice
    )

    // Verify position is unhealthy
    let health = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(health < 1.0, message: "Position should be liquidatable")

    // Pause then unpause liquidations to trigger warmup
    pauseLiquidations(signer: protocolAccount, flag: true)
    pauseLiquidations(signer: protocolAccount, flag: false)

    // Verify unpause state and warmup is active
    let params = getLiquidationParams()
    Test.assert(
        params.paused == false,
        message: "Liquidations should be unpaused"
    )
    Test.assert(
        params.lastUnpausedAt != nil,
        message: "lastUnpausedAt should be set"
    )

    let warmupSec = params.warmupSec
    Test.assert(
        warmupSec == 300,
        message: "Default warmup should be 300 seconds"
    )

    // Setup liquidator
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    mintMoet(
        signer: protocolAccount,
        to: liquidator.address,
        amount: 1000.0,
        beFailed: false
    )

    // Attempt liquidation during warmup - should fail
    let repayAmount = 2.0
    let seizeAmount = 1.0
    let liqRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-management/manual_liquidation.cdc",
        [
            pid,
            Type<@MOET.Vault>().identifier,
            flowTokenIdentifier,
            seizeAmount,
            repayAmount
        ],
        liquidator
    )

    // Assert: Liquidation should fail with warmup message
    Test.expect(liqRes, Test.beFailed())
    Test.assertError(liqRes, errorMessage: "Liquidations in warm-up period")

    // Now advance time past warmup period
    Test.moveTime(by: Fix64(warmupSec + 1))
    Test.commitBlock()

    // Attempt liquidation after warmup - should succeed
    let liqRes2 = _executeTransaction(
        "../transactions/flow-credit-market/pool-management/manual_liquidation.cdc",
        [
            pid,
            Type<@MOET.Vault>().identifier,
            flowTokenIdentifier,
            seizeAmount,
            repayAmount
        ],
        liquidator
    )

    // Assert: Liquidation should now succeed
    Test.expect(liqRes2, Test.beSucceeded())
}

/// Liquidations should succeed when DEX/oracle price divergence is within threshold.
access(all)
fun testManualLiquidation_dexOraclePriceDivergence_withinThreshold() {
    safeReset()
    let pid: UInt64 = 0

    // user setup
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)

    // open wrapped position and deposit via existing helper txs
    // debt is MOET, collateral is FLOW
    createWrappedPosition(signer: user, amount: 1000.0, vaultStoragePath: /storage/flowTokenVault, pushToDrawDownSink: true)

    // cause undercollateralization
    let oraclePrice = 0.7 // $/FLOW
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: flowTokenIdentifier, price: oraclePrice)

    // Set DEX price to 0.68 (2.94% divergence: (0.7-0.68)/0.68 = 0.0294 = 2.94%)
    let dexPriceRatio = 0.68
    addMockDexSwapper(
        signer: Test.getAccount(0x0000000000000007),
        inVaultIdentifier: flowTokenIdentifier,
        outVaultIdentifier: moetIdentifier,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: dexPriceRatio
    )

    let health = getPositionHealth(pid: pid, beFailed: false)

    // execute liquidation
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    mintMoet(signer: Test.getAccount(0x0000000000000007), to: liquidator.address, amount: 1000.0, beFailed: false)

    // Repay MOET to seize FLOW
    // DEX quote would require: 50/0.68 = 73.53 FLOW
    // Liquidator offers 72 FLOW < 73.53 FLOW (better price)
    let repayAmount = 50.0
    let seizeAmount = 72.0
    let liqRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-management/manual_liquidation.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier, seizeAmount, repayAmount],
        liquidator
    )
    // Should succeed because divergence is within threshold
    Test.expect(liqRes, Test.beSucceeded())
}

/// Liquidations should fail when DEX price is below oracle and divergence exceeds threshold.
access(all)
fun testManualLiquidation_dexOraclePriceDivergence_dexBelowOracle() {
    safeReset()
    let pid: UInt64 = 0

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)
    createWrappedPosition(signer: user, amount: 1000.0, vaultStoragePath: /storage/flowTokenVault, pushToDrawDownSink: true)

    // cause undercollateralization
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: flowTokenIdentifier, price: 0.7)

    // Set DEX price to 0.66 (6.06% divergence: (0.7-0.66)/0.66 = 0.0606 = 6.06%)
    addMockDexSwapper(
        signer: Test.getAccount(0x0000000000000007),
        inVaultIdentifier: flowTokenIdentifier,
        outVaultIdentifier: moetIdentifier,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: 0.66
    )

    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    mintMoet(signer: Test.getAccount(0x0000000000000007), to: liquidator.address, amount: 1000.0, beFailed: false)

    let liqRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-management/manual_liquidation.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier, 70.0, 50.0],
        liquidator
    )
    // Should fail because divergence exceeds threshold
    Test.expect(liqRes, Test.beFailed())
    Test.assertError(liqRes, errorMessage: "Too large difference between dex/oracle prices")
}

/// Liquidations should fail when DEX price is above oracle and divergence exceeds threshold.
access(all)
fun testManualLiquidation_dexOraclePriceDivergence_dexAboveOracle() {
    safeReset()
    let pid: UInt64 = 0

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)
    createWrappedPosition(signer: user, amount: 1000.0, vaultStoragePath: /storage/flowTokenVault, pushToDrawDownSink: true)

    // cause undercollateralization
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: flowTokenIdentifier, price: 0.7)

    // Set DEX price to 0.74 (5.71% divergence above oracle: (0.74-0.7)/0.7 = 0.0571 = 5.71%)
    addMockDexSwapper(
        signer: Test.getAccount(0x0000000000000007),
        inVaultIdentifier: flowTokenIdentifier,
        outVaultIdentifier: moetIdentifier,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: 0.74
    )

    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    mintMoet(signer: Test.getAccount(0x0000000000000007), to: liquidator.address, amount: 1000.0, beFailed: false)

    let liqRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-management/manual_liquidation.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier, 66.0, 50.0],
        liquidator
    )
    // Should fail because divergence exceeds threshold
    Test.expect(liqRes, Test.beFailed())
    Test.assertError(liqRes, errorMessage: "Too large difference between dex/oracle prices")
}

/// Liquidation should fail if liquidator offer is worse than DEX price.
access(all)
fun testManualLiquidation_liquidatorOfferWorseThanDex() {
    safeReset()
    let pid: UInt64 = 0
    let protocolAccount = Test.getAccount(0x0000000000000007)

    // Set liquidation bonus to 0 to test strict "better than DEX" validation
    setTokenLiquidationBonus(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        bonus: 0.0
    )

    // user setup
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)

    // open wrapped position and deposit via existing helper txs
    // debt is MOET, collateral is FLOW
    createWrappedPosition(signer: user, amount: 1000.0, vaultStoragePath: /storage/flowTokenVault, pushToDrawDownSink: true)

    // cause undercollateralization
    let newPrice = 0.7 // $/FLOW
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: flowTokenIdentifier, price: newPrice)

    // Update DEX price to match oracle
    addMockDexSwapper(
        signer: Test.getAccount(0x0000000000000007),
        inVaultIdentifier: flowTokenIdentifier,
        outVaultIdentifier: moetIdentifier,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: newPrice
    )

    let health = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(health < 1.0, message: "position should be unhealthy")

    // execute liquidation
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    mintMoet(signer: Test.getAccount(0x0000000000000007), to: liquidator.address, amount: 1000.0, beFailed: false)

    // Liquidator offers worse price than DEX
    // DEX quote: 50/0.7 = 71.43 FLOW
    // Liquidator offers 75 FLOW > 71.43 FLOW (worse price)
    let repayAmount = 50.0
    let seizeAmount = 75.0
    let liqRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-management/manual_liquidation.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier, seizeAmount, repayAmount],
        liquidator
    )
    // Should fail because liquidator offer is not strictly better than DEX (bonus = 0)
    Test.expect(liqRes, Test.beFailed())
    Test.assertError(liqRes, errorMessage: "Liquidation offer exceeds allowed tolerance")
}

/// Liquidation should fail when DEX/oracle divergence is too high, even when liquidator offer is competitive.
access(all)
fun testManualLiquidation_combinedEdgeCase() {
    safeReset()
    let pid: UInt64 = 0

    // user setup
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)

    // open wrapped position and deposit via existing helper txs
    // debt is MOET, collateral is FLOW
    createWrappedPosition(signer: user, amount: 1000.0, vaultStoragePath: /storage/flowTokenVault, pushToDrawDownSink: true)

    // cause undercollateralization
    let oraclePrice = 0.7 // $/FLOW
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: flowTokenIdentifier, price: oraclePrice)

    // Set DEX price to 0.64 (9.375% divergence: (0.7-0.64)/0.64 = 0.09375 = 9.375%)
    let dexPriceRatio = 0.64
    addMockDexSwapper(
        signer: Test.getAccount(0x0000000000000007),
        inVaultIdentifier: flowTokenIdentifier,
        outVaultIdentifier: moetIdentifier,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: dexPriceRatio
    )

    let health = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(health < 1.0, message: "position should be unhealthy")

    // execute liquidation
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    mintMoet(signer: Test.getAccount(0x0000000000000007), to: liquidator.address, amount: 1000.0, beFailed: false)

    // Liquidator provides better price than DEX but divergence is too high
    // DEX quote: 50/0.64 = 78.125 FLOW
    // Liquidator offers 75 FLOW < 78.125 FLOW (better than DEX)
    // But divergence is 9.375% which exceeds 3% threshold
    let repayAmount = 50.0
    let seizeAmount = 75.0
    let liqRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-management/manual_liquidation.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier, seizeAmount, repayAmount],
        liquidator
    )
    // Should fail because DEX/oracle divergence is too high, even though liquidator offer is competitive
    Test.expect(liqRes, Test.beFailed())
    Test.assertError(liqRes, errorMessage: "Too large difference between dex/oracle prices")
}

/// When liquidation bonus is 5%, manual offer at exactly bonus limit should succeed.
access(all)
fun testManualLiquidation_bonusEnabled_offerAtBonusLimit() {
    safeReset()
    let pid: UInt64 = 0
    let protocolAccount = Test.getAccount(0x0000000000000007)

    // Setup: Create unhealthy position
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)
    createWrappedPosition(
        signer: user,
        amount: 1000.0,
        vaultStoragePath: /storage/flowTokenVault,
        pushToDrawDownSink: true
    )

    // Cause undercollateralization
    let newPrice = 0.7 // $/FLOW
    setMockOraclePrice(
        signer: protocolAccount,
        forTokenIdentifier: flowTokenIdentifier,
        price: newPrice
    )
    addMockDexSwapper(
        signer: protocolAccount,
        inVaultIdentifier: flowTokenIdentifier,
        outVaultIdentifier: moetIdentifier,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: newPrice
    )

    // Set liquidation bonus to 5% (this may already be default, but explicit)
    setTokenLiquidationBonus(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        bonus: 0.05
    )

    // Verify position is unhealthy
    let health = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(health < 1.0, message: "Position should be unhealthy")

    // Setup liquidator
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    mintMoet(
        signer: protocolAccount,
        to: liquidator.address,
        amount: 1000.0,
        beFailed: false
    )

    // Attempt liquidation at exactly bonus limit
    // DEX quote: 50 MOET requires 50/0.7 = 71.428571... FLOW
    // Max with 5% bonus: 71.428571 × 1.05 ≈ 75.0 FLOW (but UFix64 precision gives 74.99999999)
    // Liquidator offers: 74.99 FLOW (at limit considering precision)
    let repayAmount = 50.0
    let seizeAmount = 74.99
    let liqRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-management/manual_liquidation.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier, seizeAmount, repayAmount],
        liquidator
    )

    // Should succeed - offer at bonus limit is allowed
    Test.expect(liqRes, Test.beSucceeded())
}

/// When liquidation bonus is 5%, manual offer within bonus tolerance should succeed.
access(all)
fun testManualLiquidation_bonusEnabled_offerWithinBonus() {
    safeReset()
    let pid: UInt64 = 0
    let protocolAccount = Test.getAccount(0x0000000000000007)

    // Setup: Create unhealthy position
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)
    createWrappedPosition(
        signer: user,
        amount: 1000.0,
        vaultStoragePath: /storage/flowTokenVault,
        pushToDrawDownSink: true
    )

    // Cause undercollateralization
    let newPrice = 0.7 // $/FLOW
    setMockOraclePrice(
        signer: protocolAccount,
        forTokenIdentifier: flowTokenIdentifier,
        price: newPrice
    )
    addMockDexSwapper(
        signer: protocolAccount,
        inVaultIdentifier: flowTokenIdentifier,
        outVaultIdentifier: moetIdentifier,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: newPrice
    )

    // Set liquidation bonus to 5%
    setTokenLiquidationBonus(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        bonus: 0.05
    )

    // Verify position is unhealthy
    let health = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(health < 1.0, message: "Position should be unhealthy")

    // Setup liquidator
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    mintMoet(
        signer: protocolAccount,
        to: liquidator.address,
        amount: 1000.0,
        beFailed: false
    )

    // Attempt liquidation within bonus tolerance
    // DEX quote: 50 MOET requires 50/0.7 = 71.428571 FLOW
    // Max with 5% bonus: 71.428571 × 1.05 = 75.0 FLOW
    // Liquidator offers: 74.0 FLOW (within bonus limit)
    let repayAmount = 50.0
    let seizeAmount = 74.0
    let liqRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-management/manual_liquidation.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier, seizeAmount, repayAmount],
        liquidator
    )

    // Should succeed - offer within bonus tolerance
    Test.expect(liqRes, Test.beSucceeded())
}

/// When liquidation bonus is 5%, manual offer exceeding bonus tolerance should fail.
access(all)
fun testManualLiquidation_bonusEnabled_offerExceedsBonus() {
    safeReset()
    let pid: UInt64 = 0
    let protocolAccount = Test.getAccount(0x0000000000000007)

    // Setup: Create unhealthy position
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)
    createWrappedPosition(
        signer: user,
        amount: 1000.0,
        vaultStoragePath: /storage/flowTokenVault,
        pushToDrawDownSink: true
    )

    // Cause undercollateralization
    let newPrice = 0.7 // $/FLOW
    setMockOraclePrice(
        signer: protocolAccount,
        forTokenIdentifier: flowTokenIdentifier,
        price: newPrice
    )
    addMockDexSwapper(
        signer: protocolAccount,
        inVaultIdentifier: flowTokenIdentifier,
        outVaultIdentifier: moetIdentifier,
        vaultSourceStoragePath: /storage/moetTokenVault_0x0000000000000007,
        priceRatio: newPrice
    )

    // Set liquidation bonus to 5%
    setTokenLiquidationBonus(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        bonus: 0.05
    )

    // Verify position is unhealthy
    let health = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(health < 1.0, message: "Position should be unhealthy")

    // Setup liquidator
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    mintMoet(
        signer: protocolAccount,
        to: liquidator.address,
        amount: 1000.0,
        beFailed: false
    )

    // Attempt liquidation exceeding bonus tolerance
    // DEX quote: 50 MOET requires 50/0.7 = 71.428571 FLOW
    // Max with 5% bonus: 71.428571 × 1.05 = 75.0 FLOW
    // Liquidator offers: 76.0 FLOW (exceeds bonus limit)
    let repayAmount = 50.0
    let seizeAmount = 76.0
    let liqRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-management/manual_liquidation.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier, seizeAmount, repayAmount],
        liquidator
    )

    // Should fail - offer exceeds bonus tolerance
    Test.expect(liqRes, Test.beFailed())
    Test.assertError(liqRes, errorMessage: "Liquidation offer exceeds allowed tolerance")
}

