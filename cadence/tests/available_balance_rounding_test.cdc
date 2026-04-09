import Test
import BlockchainHelpers

import "MOET"
import "FlowALPModels"
import "test_helpers.cdc"

// Tests that availableBalance rounds DOWN when converting from UFix128 to UFix64.
// This is critical: rounding up could return a value that, if withdrawn/borrowed,
// would violate the position's minimum health factor.
//
// Token setup:
//   FLOW: collateralFactor=0.8, borrowFactor=1.0, price=1.0
//   MOET: collateralFactor=1.0, borrowFactor=1.0, price=1.0  (default token)
//
// Scenario:
//   Deposit 100 FLOW (no debt). Available MOET borrow = 80 / 1.1 = 72.72727272727...
//   UFix64 round-down: 72.72727272
//   UFix64 round-half-up: 72.72727273  (incorrect — would breach minHealth)

access(all) let user = Test.createAccount()
access(all) let lp = Test.createAccount()

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()

    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: MOET_TOKEN_IDENTIFIER, price: 1.0)

    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // Setup LP with MOET liquidity so the user can borrow
    setupMoetVault(lp, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: lp.address, amount: 10_000.0, beFailed: false)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, lp)
    createPosition(admin: PROTOCOL_ACCOUNT, signer: lp, amount: 10_000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    // Setup user with FLOW
    setupMoetVault(user, beFailed: false)
    transferFlowTokens(to: user, amount: 1_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    snapshot = getCurrentBlockHeight()
}

access(all)
fun beforeEach() {
    if getCurrentBlockHeight() > snapshot {
        Test.reset(to: snapshot)
    }
}

// ---------------------------------------------------------------------------
// availableBalance should round down, not up, so the returned amount is always
// safe to withdraw without breaching minHealth.
//
// 100 FLOW deposited, no debt:
//   effectiveCollateral = 100 * 1.0 * 0.8 = 80
//   maxWithdraw(MOET) = 80 / minHealth(1.1) = 72.727272727272... (UFix128)
//
//   Round-down to UFix64: 72.72727272
//   Round-half-up to UFix64: 72.72727273
//
// The test asserts the round-down value, which fails with toUFix64Round and
// passes with toUFix64RoundDown.
// ---------------------------------------------------------------------------
access(all)
fun test_availableBalance_rounds_down() {
    // Open position: deposit 100 FLOW, no auto-borrow
    let pid = openPosition(flowAmount: 100.0)

    // availableBalance for MOET (no MOET credit, so this is the pure borrow path)
    let available = getAvailableBalance(
        pid: pid,
        vaultIdentifier: MOET_TOKEN_IDENTIFIER,
        pullFromTopUpSource: false,
        beFailed: false
    )

    // 80 / 1.1 = 72.72727272727... → round-down = 72.72727272
    let expectedRoundDown: UFix64 = 72.72727272
    Test.assert(available == expectedRoundDown,
        message: "availableBalance should round down: expected \(expectedRoundDown), got \(available)")
}

// ---------------------------------------------------------------------------
// Verify the safety property: borrowing the full availableBalance amount must
// succeed without breaching minHealth.
// ---------------------------------------------------------------------------
access(all)
fun test_borrowing_full_availableBalance_succeeds() {
    let pid = openPosition(flowAmount: 100.0)

    let available = getAvailableBalance(
        pid: pid,
        vaultIdentifier: MOET_TOKEN_IDENTIFIER,
        pullFromTopUpSource: false,
        beFailed: false
    )

    // Borrow the exact amount returned by availableBalance
    borrowFromPosition(
        signer: user,
        positionId: pid,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        vaultStoragePath: MOET.VaultStoragePath,
        amount: available,
        beFailed: false
    )

    // Health should be >= minHealth (1.1)
    let health = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(health >= 1.1,
        message: "Health after borrowing full availableBalance should be >= 1.1, got \(health)")
}

// --- helpers ---

access(self)
fun openPosition(flowAmount: UFix64): UInt64 {
    let openRes = _executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [flowAmount, FLOW_VAULT_STORAGE_PATH, false],
        user
    )
    Test.expect(openRes, Test.beSucceeded())
    return getLastPositionId()
}

