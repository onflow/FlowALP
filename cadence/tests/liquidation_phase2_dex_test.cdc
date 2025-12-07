import Test
import BlockchainHelpers
import "test_helpers.cdc"

import "FlowCreditMarket"
import "MOET"
import "FlowToken"
import "FlowCreditMarketMath"
import "MockDexSwapper"

access(all)
fun setup() {
    deployContracts()

    let protocolAccount = Test.getAccount(0x0000000000000007)

    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: Type<@FlowToken.Vault>().identifier, price: 1.0)
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: Type<@MOET.Vault>().identifier, beFailed: false)
    grantPoolCapToConsumer()
    addSupportedTokenSimpleInterestCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: Type<@FlowToken.Vault>().identifier,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )
}

access(all)
fun test_liquidation_via_dex() {
    let pid: UInt64 = 0

    // user setup
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1000.0)

    _executeTransaction(
        "./transactions/mock-flow-credit-market-consumer/create_wrapped_position.cdc",
        [1000.0, /storage/flowTokenVault, true],
        user
    )

    // make unhealthy
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: Type<@FlowToken.Vault>().identifier, price: 0.7)
    let h0 = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(FlowCreditMarketMath.toUFix64Round(h0) < 1.0)

    // perform liquidation via mock dex using signer as protocol
    let protocol = Test.getAccount(0x0000000000000007)
    // allowlist MockDexSwapper
    let swapperTypeId = Type<MockDexSwapper.Swapper>().identifier
    let allowTx = Test.Transaction(
        code: Test.readFile("../transactions/flow-credit-market/pool-governance/set_dex_liquidation_config.cdc"),
        authorizers: [protocol.address],
        signers: [protocol],
        arguments: [nil, [swapperTypeId], nil, nil, nil]
    )
    let allowRes = Test.executeTransaction(allowTx)
    Test.expect(allowRes, Test.beSucceeded())
    // ensure protocol MOET liquidity for DEX swapper source
    setupMoetVault(protocol, beFailed: false)
    mintMoet(signer: protocol, to: protocol.address, amount: 1_000_000.0, beFailed: false)
    let txRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-management/liquidate_via_mock_dex.cdc",
        [pid, Type<@MOET.Vault>(), Type<@FlowToken.Vault>(), 1000.0, 0.0, 1.42857143],
        protocol
    )
    Test.expect(txRes, Test.beSucceeded())

    // HF should improve to at/near target
    let h1 = getPositionHealth(pid: pid, beFailed: false)
    let target = FlowCreditMarketMath.toUFix128(1.05)
    let tol = FlowCreditMarketMath.toUFix128(0.00001)
    Test.assert(h1 >= target - tol)
}


access(all)
fun test_mockdex_quote_math_placeholder_noop() {
    // Moved to dedicated file to avoid redeploy collisions in CI
    Test.assert(true)
}


