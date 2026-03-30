import Test
import BlockchainHelpers

import "FlowALPv0"
import "MOET"

import "test_helpers.cdc"

access(all) let alice = Test.createAccount()

access(all)
fun setup() {
    deployContracts()
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: MOET_TOKEN_IDENTIFIER, price: 1.0)
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
}

// -----------------------------------------------------------------------------
// Test: setInsuranceSwapper with valid configuration should succeed
// Verifies that a valid insurance swapper can be set for a token type
// -----------------------------------------------------------------------------
access(all)
fun test_setInsuranceSwapper_success() {
    let res = setInsuranceSwapper(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    // verify swapper is configured
    Test.assertEqual(true, insuranceSwapperExists(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER))
}

// -----------------------------------------------------------------------------
// Test: setInsuranceSwapper can update existing swapper
// Verifies that an existing swapper can be replaced with a new one
// -----------------------------------------------------------------------------
access(all)
fun test_setInsuranceSwapper_updateExistingSwapper_success() {
    // set initial swapper
    let initialPriceRatio = 1.0
    let res = setInsuranceSwapper(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        priceRatio: initialPriceRatio,
    )
    Test.expect(res, Test.beSucceeded())

    // update to new swapper with different price ratio
    let updatedPriceRatio = 2.0
    let updatedRes = setInsuranceSwapper(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        priceRatio: updatedPriceRatio,
    )
    Test.expect(updatedRes, Test.beSucceeded())

    // verify swapper is still configured
    Test.assertEqual(true, insuranceSwapperExists(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER))
}

// -----------------------------------------------------------------------------
// Test: removeInsuranceSwapper should remove configured swapper
// Verifies that an insurance swapper can be removed after being set
// -----------------------------------------------------------------------------
access(all)
fun test_removeInsuranceSwapper_success() {
    // set a swapper
    let res = setInsuranceSwapper(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    // verify swapper is configured
    Test.assertEqual(true, insuranceSwapperExists(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER))

    // remove swapper
    let removeResult = removeInsuranceSwapper(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
    )
    Test.expect(removeResult, Test.beSucceeded())

    // verify swapper is no longer configured
    Test.assertEqual(false, insuranceSwapperExists(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER))
}

// -----------------------------------------------------------------------------
// Test: test_remove_insuranceSwapper_failed should not remove configured swapper
// Verifies that an insurance swapper cannot be removed when insurance rate is being set
// -----------------------------------------------------------------------------
access(all)
fun test_remove_insuranceSwapper_failed() {
    // set a swapper
    var res = setInsuranceSwapper(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    // verify swapper is configured
    Test.assertEqual(true, insuranceSwapperExists(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER))

    // set insurance rate
    res = setInsuranceRate(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        insuranceRate: 0.001,
    )
    Test.expect(res, Test.beSucceeded())

    // remove swapper
    let removeResult = removeInsuranceSwapper(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
    )
    Test.expect(removeResult, Test.beFailed())
    Test.assertError(removeResult, errorMessage: "Cannot remove insurance swapper while insurance rate is non-zero for \(MOET_TOKEN_IDENTIFIER)")

    // verify swapper is still exist
    Test.assertEqual(true, insuranceSwapperExists(tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER))
}

// -----------------------------------------------------------------------------
// Test: setInsuranceSwapper without EGovernance entitlement should fail
// Verifies that accounts without EGovernance entitlement cannot set swapper
// -----------------------------------------------------------------------------
access(all)
fun test_setInsuranceSwapper_withoutEGovernanceEntitlement_fails() {
    let res = setInsuranceSwapper(
        signer: alice,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        priceRatio: 1.0,
    )

    // should fail due to missing EGovernance entitlement or missing Pool
    Test.expect(res, Test.beFailed())
}

// -----------------------------------------------------------------------------
// Test: setInsuranceSwapper with invalid token identifier should fail
// Verifies that non-existent token types are rejected
// -----------------------------------------------------------------------------
access(all)
fun test_setInsuranceSwapper_invalidTokenTypeIdentifier_fails() {
    let invalidTokenIdentifier = "InvalidTokenType"

    let res = setInsuranceSwapper(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: invalidTokenIdentifier,
        priceRatio: 1.0,
    )

    Test.expect(res, Test.beFailed())
    Test.assertError(res, errorMessage: "Invalid tokenTypeIdentifier")
}

// -----------------------------------------------------------------------------
// Test: setInsuranceSwapper with empty token identifier should fail
// Verifies that empty string token identifiers are rejected
// -----------------------------------------------------------------------------
access(all)
fun test_setInsuranceSwapper_emptyTokenTypeIdentifier_fails() {
    let emptyTokenIdentifier = ""

    let res = setInsuranceSwapper(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: emptyTokenIdentifier,
        priceRatio: 1.0,
    )

    Test.expect(res, Test.beFailed())
    Test.assertError(res, errorMessage: "Invalid tokenTypeIdentifier")
}

// -----------------------------------------------------------------------------
// Test: setInsuranceSwapper with wrong output type should fail
// Swapper must output MOET (insurance fund denomination)
// -----------------------------------------------------------------------------
access(all)
fun test_setInsuranceSwapper_wrongOutputType_fails() {
    // try to set a swapper that doesn't output MOET (outputs FLOW_TOKEN_IDENTIFIER instead)
    let res = _executeTransaction(
        "./transactions/flow-alp/egovernance/set_insurance_swapper_mock.cdc",
        [MOET_TOKEN_IDENTIFIER, 1.0, MOET_TOKEN_IDENTIFIER, FLOW_TOKEN_IDENTIFIER],
        PROTOCOL_ACCOUNT
    )

    Test.expect(res, Test.beFailed())
    Test.assertError(res, errorMessage: "Swapper output type must be MOET")
}

// -----------------------------------------------------------------------------
// Test: setInsuranceSwapper with wrong input type should fail
// Swapper input type must match the token type being configured
// -----------------------------------------------------------------------------
access(all)
fun test_setInsuranceSwapper_wrongInputType_fails() {
    // try to set a swapper with wrong input type (FLOW_TOKEN_IDENTIFIER instead of MOET_TOKEN_IDENTIFIER)
    let res = _executeTransaction(
        "./transactions/flow-alp/egovernance/set_insurance_swapper_mock.cdc",
        [MOET_TOKEN_IDENTIFIER, 1.0, FLOW_TOKEN_IDENTIFIER, MOET_TOKEN_IDENTIFIER],
        PROTOCOL_ACCOUNT
    )

    Test.expect(res, Test.beFailed())
    Test.assertError(res, errorMessage: "Swapper input type must match token type")
}

// -----------------------------------------------------------------------------
/// Swapper returns 10 % less collateral than quoted.
///
/// The protocol validates `seizeAmount < quote.inAmount`, which is checked
/// before the swap executes, liquidation tx must revert.
// -----------------------------------------------------------------------------

access(all)
fun test_insuranceSwapper_returns_less_than_quoted() {
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    let mintRes = mintFlow(to: user, amount: 1000.0)
    Test.expect(mintRes, Test.beSucceeded())

    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.65,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)

    createPosition(
        admin: PROTOCOL_ACCOUNT,
        signer: user,
        amount: 1000.0,
        vaultStoragePath: FLOW_VAULT_STORAGE_PATH,
        pushToDrawDownSink: true
    )
    let pid = getLastPositionId()

    // change oracle price FLOW $1.00 → $0.70
    setMockOraclePrice(
        signer: PROTOCOL_ACCOUNT,
        forTokenIdentifier: FLOW_TOKEN_IDENTIFIER,
        price: 0.70
    )

    // configure the DEX swapper to return only 90 % of what it quotes
    // (simulates slippage / malicious swapper).
    // priceRatio here represents actual tokens-out per token-in; setting it 10 %
    // below the oracle causes the inferred DEX price to diverge by ~11 %, which
    // exceeds the 3 % (300 bps) threshold -> transaction must revert.
    let manipulatedRatio = 0.63   // 0.70 * 0.90 = 0.63
    setMockDexPriceForPair(
        signer: PROTOCOL_ACCOUNT,
        inVaultIdentifier: FLOW_TOKEN_IDENTIFIER,
        outVaultIdentifier: MOET_TOKEN_IDENTIFIER,
        vaultSourceStoragePath: MOET.VaultStoragePath,
        priceRatio: manipulatedRatio
    )

    Test.assert(getPositionHealth(pid: pid, beFailed: false) < 1.0,message: "position must be underwater before liquidation attempt")

    let liquidator = Test.createAccount()
    setupMoetVault(liquidator, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: liquidator.address, amount: 500.0, beFailed: false)

    // DEX quote at manipulatedRatio 0.63: 50 / 0.63 ≈ 79.37 FLOW required.
    // Liquidator offers 70 FLOW < 79.37 → passes better-than-DEX check.
    // But DEX implied price = 0.63, oracle = 0.70:
    //   deviation = |0.70 - 0.63| / 0.63 ≈ 11.1 % > 3 % threshold
    let liqRes = manualLiquidation(
        signer: liquidator,
        pid: pid,
        debtVaultIdentifier: MOET_TOKEN_IDENTIFIER,
        seizeVaultIdentifier: FLOW_TOKEN_IDENTIFIER,
        seizeAmount: 70.0,
        repayAmount: 50.0
    )
    Test.expect(liqRes, Test.beFailed())
    Test.assertError(liqRes, errorMessage: "DEX/oracle price deviation too large")

    // collateral must be unchanged
    let details = getPositionDetails(pid: pid, beFailed: false)
    let flowCredit = getCreditBalanceForType(
        details: details,
        vaultType: CompositeType(FLOW_TOKEN_IDENTIFIER)!
    )
    Test.assertEqual(1000.0, flowCredit)
}
