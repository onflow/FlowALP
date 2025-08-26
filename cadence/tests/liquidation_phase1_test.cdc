import Test
import "MOET"
import "TidalProtocol"
import "test_helpers.cdc"

access(all) let flowTokenIdentifier = "A.0000000000000003.FlowToken.Vault"

access(all)
fun setup() {
    deployContracts()
}

access(all)
fun test_liquidation_phase1_quote_and_execute() {
    let protocolAccount = Test.getAccount(0x0000000000000007)

    // price setup and pool creation
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: 1.0)
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
    transferFlowTokens(to: user, amount: 1000.0)

    // open wrapped position and deposit via existing helper txs
    let openRes = _executeTransaction(
        "./transactions/mock-tidal-protocol-consumer/create_wrapped_position.cdc",
        [1000.0, /storage/flowTokenVault, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // cause undercollateralization
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: 0.5)

    // quote liquidation
    let quoteRes = _executeScript(
        "../scripts/tidal-protocol/quote_liquidation.cdc",
        [0 as UInt64, Type<@MOET.Vault>().identifier, flowTokenIdentifier]
    )
    Test.expect(quoteRes, Test.beSucceeded())
    let quote = quoteRes.returnValue as! TidalProtocol.LiquidationQuote
    Test.assert(quote.requiredRepay > 0.0)
    Test.assert(quote.seizeAmount > 0.0)
}
