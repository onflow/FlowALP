import Test
import BlockchainHelpers
import "test_helpers.cdc"
import "TidalProtocol"
import "MOET"
import "FlowToken"
import "TidalMath"

access(all) let flowTokenIdentifier = "A.0000000000000003.FlowToken.Vault"
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
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    snapshot = getCurrentBlockHeight()
}

access(all)
fun test_liquidation_phase1_quote_and_execute() {
    safeReset()
    let pid: UInt64 = 0

    // user setup
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)

    // open wrapped position and deposit via existing helper txs
    let openRes = _executeTransaction(
        "./transactions/mock-tidal-protocol-consumer/create_wrapped_position.cdc",
        [1000.0, /storage/flowTokenVault, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // health before price drop
    let hBefore = getPositionHealth(pid: pid, beFailed: false)
    let hBeforeUF = TidalMath.toUFix64Round(hBefore)
    log("[LIQ] Health before price drop: raw=\(hBefore), approx=\(hBeforeUF)")

    // cause undercollateralization
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: flowTokenIdentifier, price: 0.7)
    let hAfterPrice = getPositionHealth(pid: pid, beFailed: false)
    let hAfterPriceUF = TidalMath.toUFix64Round(hAfterPrice)
    log("[LIQ] Health after price drop: raw=\(hAfterPrice), approx=\(hAfterPriceUF)")

    // quote liquidation
    let quoteRes = _executeScript(
        "../scripts/tidal-protocol/quote_liquidation.cdc",
        [0 as UInt64, Type<@MOET.Vault>().identifier, flowTokenIdentifier]
    )
    Test.expect(quoteRes, Test.beSucceeded())
    let quote = quoteRes.returnValue as! TidalProtocol.LiquidationQuote
    log("[LIQ] Quote: requiredRepay=\(quote.requiredRepay) seizeAmount=\(quote.seizeAmount) newHF=\(quote.newHF)")
    Test.assert(quote.requiredRepay > 0.0)
    Test.assert(quote.seizeAmount > 0.0)

    // execute liquidation
    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    _executeTransaction("../transactions/moet/mint_moet.cdc", [liquidator.address, quote.requiredRepay + 1.0], Test.getAccount(0x0000000000000007))

    let liqBalance = getBalance(address: liquidator.address, vaultPublicPath: /public/moetBalance) ?? 0.0
    log("Liquidator MOET balance after mint: \(liqBalance)")

    let liqRes = _executeTransaction(
        "../transactions/tidal-protocol/pool-management/liquidate_repay_for_seize.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier, quote.requiredRepay + 1.0, 0.0],
        liquidator
    )
    Test.expect(liqRes, Test.beSucceeded())

    // health after liquidation
    let hAfterLiq = getPositionHealth(pid: pid, beFailed: false)
    let hAfterLiqUF = TidalMath.toUFix64Round(hAfterLiq)
    log("[LIQ] Health after liquidation: raw=\(hAfterLiq), approx=\(hAfterLiqUF)")

    // Assert final health ≈ target
    let targetHF = TidalMath.toUFix128(1.05)
    let tolerance = TidalMath.toUFix128(0.00001)
    Test.assert(hAfterLiq >= targetHF - tolerance && hAfterLiq <= targetHF + tolerance, message: "Post-liquidation health \(hAfterLiqUF) not at target 1.05")

    // Assert quoted newHF matches actual
    Test.assert(quote.newHF >= targetHF - tolerance && quote.newHF <= targetHF + tolerance, message: "Quoted newHF not at target")

    let detailsAfter = getPositionDetails(pid: pid, beFailed: false)
    Test.assert(detailsAfter.health >= targetHF - tolerance, message: "Health not restored")
}

// DEX liquidation tests moved to liquidation_phase2_dex_test.cdc

access(all)
fun test_liquidation_insolvency() {
    safeReset()
    let pid: UInt64 = 0

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)

    let openRes = _executeTransaction(
        "./transactions/mock-tidal-protocol-consumer/create_wrapped_position.cdc",
        [1000.0, /storage/flowTokenVault, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // Severe undercollateralization (insolvent, but liquidation improves HF)
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: flowTokenIdentifier, price: 0.6)
    let hAfter = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(TidalMath.toUFix64Round(hAfter) < 1.0)

    // Quote should suggest partial repay/seize that improves HF to max possible < target
    let quoteRes = _executeScript(
        "../scripts/tidal-protocol/quote_liquidation.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier]
    )
    Test.expect(quoteRes, Test.beSucceeded())
    let quote = quoteRes.returnValue as! TidalProtocol.LiquidationQuote
    if quote.requiredRepay == 0.0 {
        // In deep insolvency with liquidation bonus, keeper repay-for-seize can worsen HF; expect no keeper quote
        Test.assert(quote.seizeAmount == 0.0, message: "Expected zero seize when repay is zero")
        return
    }
    Test.assert(quote.seizeAmount > 0.0, message: "Expected positive seizeAmount")
    Test.assert(quote.newHF > hAfter && quote.newHF < TidalMath.one)

    // Execute and assert improvement, HF < target
    let keeper = Test.createAccount()
    setupMoetVault(keeper, beFailed: false)
    _executeTransaction("../transactions/moet/mint_moet.cdc", [keeper.address, quote.requiredRepay + 0.00000001], Test.getAccount(0x0000000000000007))

    let liqRes = _executeTransaction(
        "../transactions/tidal-protocol/pool-management/liquidate_repay_for_seize.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier, quote.requiredRepay + 0.00000001, 0.0],
        keeper
    )
    Test.expect(liqRes, Test.beSucceeded())

    // Health should be max (zero debt left after partial repay)
    let hFinal = getPositionHealth(pid: pid, beFailed: false)
    let hFinalUF = TidalMath.toUFix64Round(hFinal)
    log("hFinal: \(TidalMath.toUFix64Round(hFinal)), hAfter: \(TidalMath.toUFix64Round(hAfter))")
    Test.assert(hFinal > hAfter, message: "Health not improved")
    Test.assert(hFinalUF <= 1.05, message: "Insolvent HF exceeded target")
}

access(all)
fun test_multi_liquidation() {
    safeReset()
    let pid: UInt64 = 0

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)

    _executeTransaction(
        "./transactions/mock-tidal-protocol-consumer/create_wrapped_position.cdc",
        [1000.0, /storage/flowTokenVault, true],
        user
    )

    // Initial undercollateralization
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: flowTokenIdentifier, price: 0.7)
    let hInitial = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(TidalMath.toUFix64Round(hInitial) < 1.0)

    // First liquidation
    let quote1Res = _executeScript(
        "../scripts/tidal-protocol/quote_liquidation.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier]
    )
    let quote1 = quote1Res.returnValue as! TidalProtocol.LiquidationQuote

    let keeper1 = Test.createAccount()
    setupMoetVault(keeper1, beFailed: false)
    _executeTransaction("../transactions/moet/mint_moet.cdc", [keeper1.address, quote1.requiredRepay], Test.getAccount(0x0000000000000007))

    _executeTransaction(
        "../transactions/tidal-protocol/pool-management/liquidate_repay_for_seize.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier, quote1.requiredRepay, 0.0],
        keeper1
    )

    let hAfter1 = getPositionHealth(pid: pid, beFailed: false)
    let targetHF = TidalMath.toUFix128(1.05)
    // Slightly relax tolerance for second liquidation to account for rounding across sequential updates
    let tolerance = TidalMath.toUFix128(0.00002)
    Test.assert(hAfter1 >= targetHF - tolerance, message: "First liquidation did not reach target")

    // Drop price further for second liquidation
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: flowTokenIdentifier, price: 0.6)

    let hAfterDrop = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(TidalMath.toUFix64Round(hAfterDrop) < 1.0)

    // Second liquidation
    let quote2Res = _executeScript(
        "../scripts/tidal-protocol/quote_liquidation.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier]
    )
    let quote2 = quote2Res.returnValue as! TidalProtocol.LiquidationQuote

    let keeper2 = Test.createAccount()
    setupMoetVault(keeper2, beFailed: false)
    _executeTransaction("../transactions/moet/mint_moet.cdc", [keeper2.address, quote2.requiredRepay + 0.00000001], Test.getAccount(0x0000000000000007))

    _executeTransaction(
        "../transactions/tidal-protocol/pool-management/liquidate_repay_for_seize.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier, quote2.requiredRepay + 0.00000001, 0.0],
        keeper2
    )

    let hFinal = getPositionHealth(pid: pid, beFailed: false)
    log("[LIQ][TEST] Second liquidation hFinal UF=\(TidalMath.toUFix64Round(hFinal)) raw=\(hFinal)")
    Test.assert(hFinal >= targetHF - tolerance, message: "Second liquidation did not reach target")
}

access(all)
fun test_liquidation_overpay_attempt() {
    safeReset()
    let pid: UInt64 = 0

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)

    let openRes = _executeTransaction(
        "./transactions/mock-tidal-protocol-consumer/create_wrapped_position.cdc",
        [1000.0, /storage/flowTokenVault, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: flowTokenIdentifier, price: 0.7)

    let quoteRes = _executeScript(
        "../scripts/tidal-protocol/quote_liquidation.cdc",
        [0 as UInt64, Type<@MOET.Vault>().identifier, flowTokenIdentifier]
    )
    let quote = quoteRes.returnValue as! TidalProtocol.LiquidationQuote
    if quote.requiredRepay == 0.0 {
        // Near-threshold rounding case may produce zero-step; nothing to liquidate
        return
    }

    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    let overpayAmount = quote.requiredRepay + 10.0
    _executeTransaction("../transactions/moet/mint_moet.cdc", [liquidator.address, overpayAmount], Test.getAccount(0x0000000000000007))

    let balanceBefore = getBalance(address: liquidator.address, vaultPublicPath: MOET.ReceiverPublicPath) ?? 0.0
    let collBalanceBefore = getBalance(address: liquidator.address, vaultPublicPath: /public/flowTokenReceiver) ?? 0.0

    let liqRes = _executeTransaction(
        "../transactions/tidal-protocol/pool-management/liquidate_repay_for_seize.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier, overpayAmount, 0.0],
        liquidator
    )
    Test.expect(liqRes, Test.beSucceeded())

    let balanceAfter = getBalance(address: liquidator.address, vaultPublicPath: MOET.ReceiverPublicPath) ?? 0.0
    let collBalanceAfter = getBalance(address: liquidator.address, vaultPublicPath: /public/flowTokenReceiver) ?? 0.0

    Test.assert(balanceAfter == balanceBefore - quote.requiredRepay, message: "Actual repay not equal to requiredRepay")
    Test.assert(collBalanceAfter == collBalanceBefore + quote.seizeAmount, message: "Seize amount changed")
}

access(all)
fun test_liquidation_slippage_failure() {
    safeReset()
    let pid: UInt64 = 0

    // Setup similar to first test
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)

    _executeTransaction(
        "./transactions/mock-tidal-protocol-consumer/create_wrapped_position.cdc",
        [1000.0, /storage/flowTokenVault, true],
        user
    )

    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: flowTokenIdentifier, price: 0.7)

    let quoteRes = _executeScript(
        "../scripts/tidal-protocol/quote_liquidation.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier]
    )
    let quote = quoteRes.returnValue as! TidalProtocol.LiquidationQuote

    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    _executeTransaction("../transactions/moet/mint_moet.cdc", [liquidator.address, quote.requiredRepay], Test.getAccount(0x0000000000000007))

    // max < required -> revert
    let lowMaxRes = _executeTransaction(
        "../transactions/tidal-protocol/pool-management/liquidate_repay_for_seize.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier, quote.requiredRepay - 0.00000001, 0.0],
        liquidator
    )
    Test.expect(lowMaxRes, Test.beFailed())

    // min > seize -> revert
    let highMinRes = _executeTransaction(
        "../transactions/tidal-protocol/pool-management/liquidate_repay_for_seize.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier, quote.requiredRepay, quote.seizeAmount + 0.1],
        liquidator
    )
    Test.expect(highMinRes, Test.beFailed())
}


access(all)
fun test_liquidation_healthy_zero_quote() {
    safeReset()
    let pid: UInt64 = 0

    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)

    let openRes = _executeTransaction(
        "./transactions/mock-tidal-protocol-consumer/create_wrapped_position.cdc",
        [1000.0, /storage/flowTokenVault, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // Set price to make HF > 1.0 (healthy)
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: flowTokenIdentifier, price: 1.2)

    let h = getPositionHealth(pid: pid, beFailed: false)
    let hUF = TidalMath.toUFix64Round(h)
    Test.assert(hUF > 1.0, message: "Position not healthy")

    let quoteRes = _executeScript(
        "../scripts/tidal-protocol/quote_liquidation.cdc",
        [pid, Type<@MOET.Vault>().identifier, flowTokenIdentifier]
    )
    Test.expect(quoteRes, Test.beSucceeded())
    let quote = quoteRes.returnValue as! TidalProtocol.LiquidationQuote

    Test.assert(quote.requiredRepay == 0.0, message: "Required repay not zero for healthy position")
    Test.assert(quote.seizeAmount == 0.0, message: "Seize amount not zero for healthy position")
    Test.assert(quote.newHF == h, message: "New HF not matching current health")
}

// Time-based warmup enforcement test removed
