import Test
import BlockchainHelpers

import "MOET"
import "FlowALPv0"
import "FlowToken"
import "test_helpers.cdc"

// -----------------------------------------------------------------------------
// Close Position — Vault Scenario Test (reproduces failure from vault-on-top)
//
// Mirrors the scenario from the other repo (RebalanceYieldVaultScenario4):
// - FLOW collateral at low price ($0.03), user borrows MOET
// - FLOW price drops to $0.02, rebalance
// - User closes position
//
// Why you might not get all FLOW back: the pool enforces a per-user deposit
// limit (default depositLimitFraction = 5% of depositCapacityCap). So only
// 50k FLOW would be accepted and the rest queued; on close you only withdraw
// the 50k in the position. We set depositLimitFraction to 1.0 for FLOW in
// setup so the full deposit is accepted.
// -----------------------------------------------------------------------------

access(all) var snapshot: UInt64 = 0

// Helper: get FLOW collateral (credit) from position details
access(all)
fun getFlowCollateralFromPosition(pid: UInt64): UFix64 {
    let details = getPositionDetails(pid: pid, beFailed: false)
    for balance in details.balances {
        if balance.vaultType == Type<@FlowToken.Vault>() {
            if balance.direction == FlowALPv0.BalanceDirection.Credit {
                return balance.balance
            }
        }
    }
    return 0.0
}

// Helper: get MOET debt (debit) from position details
access(all)
fun getMOETDebtFromPosition(pid: UInt64): UFix64 {
    let details = getPositionDetails(pid: pid, beFailed: false)
    for balance in details.balances {
        if balance.vaultType == Type<@MOET.Vault>() {
            if balance.direction == FlowALPv0.BalanceDirection.Debit {
                return balance.balance
            }
        }
    }
    return 0.0
}

access(all)
fun setup() {
    deployContracts()

    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 0.03)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: MOET_TOKEN_IDENTIFIER, price: 1.0)

    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    addSupportedTokenKinkCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        optimalUtilization: 0.80,
        baseRate: 0.01,
        slope1: 0.04,
        slope2: 0.60,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )
    // Per-user deposit limit defaults to 5% of cap = 50k; without this, a 500k deposit
    // would only accept 50k and queue the rest, so on close you'd get only 50k FLOW back.
    setDepositLimitFraction(signer: PROTOCOL_ACCOUNT, tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER, fraction: 1.0)

    // LP provides MOET so the borrower can draw
    let lp = Test.createAccount()
    setupMoetVault(lp, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: lp.address, amount: 100_000.0, beFailed: false)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, lp)
    createPosition(signer: lp, amount: 50_000.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)

    snapshot = getCurrentBlockHeight()
}

// Scenario: large FLOW position at low FLOW price; FLOW drops; rebalance; close.
// Asserts user must not receive more FLOW than pre-open (same assertion that fails in vault-on-top).
access(all)
fun test_closePosition_afterLowFlowPriceAndRebalance() {
    let fundingAmount = 1_000_000.0
    let flowPriceDecrease = 0.02   // FLOW: $0.03 (setup) → $0.02

    let user = Test.createAccount()
    mintFlow(to: user, amount: fundingAmount)
    setupMoetVault(user, beFailed: false)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    let flowBeforeOpen = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!

    // Open position (pushToDrawDownSink = true → borrow MOET)
    let openRes = _executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [fundingAmount / 2.0, FLOW_VAULT_STORAGE_PATH, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    let pid = 1 as UInt64
    let collateralBefore = getFlowCollateralFromPosition(pid: pid)
    let debtBefore = getMOETDebtFromPosition(pid: pid)
    log("[VaultScenario] Position opened: FLOW collateral ~ \(collateralBefore), MOET debt ~ \(debtBefore)")

    // Phase 1: FLOW price drops from $0.03 to $0.02
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: flowPriceDecrease)

    rebalancePosition(signer: PROTOCOL_ACCOUNT, pid: pid, force: true, beFailed: false)

    let collateralAfterDrop = getFlowCollateralFromPosition(pid: pid)
    let debtAfterDrop = getMOETDebtFromPosition(pid: pid)
    log("[VaultScenario] After rebalance (FLOW=$\(flowPriceDecrease)): collateral ~ \(collateralAfterDrop), debt ~ \(debtAfterDrop)")

    // User needs enough MOET to repay debt when closing
    let moetBalance = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    let debtNow = getMOETDebtFromPosition(pid: pid)
    if debtNow > moetBalance {
        mintMoet(signer: PROTOCOL_ACCOUNT, to: user.address, amount: debtNow - moetBalance + 1.0, beFailed: false)
    }

    let closeRes = _executeTransaction(
        "../transactions/flow-alp/position/repay_and_close_position.cdc",
        [pid],
        user
    )
    Test.expect(closeRes, Test.beSucceeded())

    let flowAfterClose = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    Test.assert(flowAfterClose >= flowBeforeOpen - 0.02, message: "User should get collateral back (minus small tolerance)")
    // Same assertion that fails in the other repo when closePosition rounds/credits slightly more FLOW
    Test.assert(flowAfterClose <= flowBeforeOpen, message: "User must not receive more FLOW than pre-open")

    let detailsAfter = getPositionDetails(pid: pid, beFailed: false)
    for balance in detailsAfter.balances {
        Test.assertEqual(0.0, balance.balance)
    }
    log("[VaultScenario] Test complete")
}
