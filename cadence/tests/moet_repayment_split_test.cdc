import Test
import BlockchainHelpers

import "MOET"
import "FlowALPv0"
import "FlowALPModels"
import "test_helpers.cdc"

access(all)
fun setup() {
    deployContracts()
}

/// Regression test for MOET over-repayment routing:
/// when deposit amount > debt, only the debt portion should be treated as repayment,
/// and the surplus must be routed as collateral into reserves.
access(all)
fun testMoetOverRepaymentSplitsRepayAndCollateral() {
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)

    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
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

    // Open position with FLOW collateral and auto-borrow MOET.
    let openRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [1_000.0, FLOW_VAULT_STORAGE_PATH, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    let pid: UInt64 = 0
    let debtAmount = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    Test.assert(debtAmount > 0.0, message: "Expected non-zero MOET debt to be borrowed")

    let surplus: UFix64 = 50.0
    mintMoet(signer: PROTOCOL_ACCOUNT, to: user.address, amount: surplus, beFailed: false)

    let reserveBefore = getReserveBalance(vaultIdentifier: MOET_TOKEN_IDENTIFIER)

    // Over-repay by exactly `surplus`.
    depositToPosition(
        signer: user,
        positionID: pid,
        amount: debtAmount + surplus,
        vaultStoragePath: MOET.VaultStoragePath,
        pushToDrawDownSink: false
    )

    let reserveAfter = getReserveBalance(vaultIdentifier: MOET_TOKEN_IDENTIFIER)
    let reserveDelta = reserveAfter - reserveBefore

    Test.assert(
        reserveDelta >= surplus - 0.01 && reserveDelta <= surplus + 0.01,
        message: "Expected MOET reserve delta ~".concat(surplus.toString()).concat(", got ").concat(reserveDelta.toString())
    )

    let moetBalance = getPositionBalance(pid: pid, vaultID: MOET_TOKEN_IDENTIFIER)
    Test.assertEqual(FlowALPModels.BalanceDirection.Credit, moetBalance.direction)
    Test.assert(
        moetBalance.balance >= surplus - 0.01 && moetBalance.balance <= surplus + 0.01,
        message: "Expected MOET position credit ~".concat(surplus.toString()).concat(", got ").concat(moetBalance.balance.toString())
    )

    // Surplus should be withdrawable because it is reserve-backed collateral.
    withdrawFromPosition(
        signer: user,
        positionId: pid,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        amount: surplus,
        pullFromTopUpSource: false
    )

    let userMoetAfter = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    Test.assert(
        userMoetAfter >= surplus - 0.01 && userMoetAfter <= surplus + 0.01,
        message: "Expected user MOET balance ~".concat(surplus.toString()).concat(", got ").concat(userMoetAfter.toString())
    )
}
