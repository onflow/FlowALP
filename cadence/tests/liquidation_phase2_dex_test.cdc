import Test
import BlockchainHelpers
import "test_helpers.cdc"

import "TidalProtocol"
import "MOET"
import "FlowToken"
import "DeFiActionsMathUtils"
import "MockDexSwapper"

access(all)
fun setup() {
    deployContracts()

    let protocolAccount = Test.getAccount(0x0000000000000007)

    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: Type<@FlowToken.Vault>().identifier, price: 1.0)
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: Type<@MOET.Vault>().identifier, beFailed: false)
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
        "./transactions/mock-tidal-protocol-consumer/create_wrapped_position.cdc",
        [1000.0, /storage/flowTokenVault, true],
        user
    )

    // make unhealthy
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: Type<@FlowToken.Vault>().identifier, price: 0.7)
    let h0 = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(DeFiActionsMathUtils.toUFix64Round(h0) < 1.0)

    // perform liquidation via mock dex using signer as protocol
    let protocol = Test.getAccount(0x0000000000000007)
    let txRes = _executeTransaction(
        "../transactions/tidal-protocol/pool-management/liquidate_via_mock_dex.cdc",
        [pid, Type<@MOET.Vault>(), Type<@FlowToken.Vault>(), 1000.0, 0.0, 1.0],
        protocol
    )
    Test.expect(txRes, Test.beSucceeded())

    // HF should improve to at/near target
    let h1 = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(h1 >= UInt128(1050000000000000000000000 - 10000000000000000000))
}


