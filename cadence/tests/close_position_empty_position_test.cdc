import Test
import BlockchainHelpers

import "MOET"
import "FlowALPv0"
import "test_helpers.cdc"

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
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    snapshot = getCurrentBlockHeight()
}

/// Regression test for closePosition empty-withdrawals map handling.
///
/// Scenario:
/// 1) Open a position with collateral and no debt.
/// 2) Withdraw all collateral so the position has no balances.
/// 3) Close the position.
///
/// Expected: close succeeds (must not panic on empty vault array).
access(all)
fun test_closePosition_afterFullWithdrawal_noDebtNoCollateral() {
    safeReset()

    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)
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
    mintFlow(to: user, amount: 1_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    let openRes = _executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [100.0, FLOW_VAULT_STORAGE_PATH, false],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    let withdrawRes = _executeTransaction(
        "./transactions/position-manager/withdraw_from_position.cdc",
        [UInt64(0), FLOW_TOKEN_IDENTIFIER, 100.0, false],
        user
    )
    Test.expect(withdrawRes, Test.beSucceeded())

    let closeRes = _executeTransaction(
        "../transactions/flow-alp/position/repay_and_close_position.cdc",
        [UInt64(0)],
        user
    )
    Test.expect(closeRes, Test.beSucceeded())

    let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    Test.assert(
        flowBalanceAfter >= 1_000.0 - DEFAULT_UFIX_VARIANCE,
        message: "Expected all FLOW to be returned after full withdrawal and close"
    )
}
