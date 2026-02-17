import Test
import BlockchainHelpers

import "MOET"
import "FlowALPv1"
import "DeFiActions"
import "DeFiActionsUtils"
import "FlowToken"
import "test_helpers.cdc"
import "FungibleToken"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) let protocolConsumerAccount = Test.getAccount(0x0000000000000008)
access(all) let userAccount = Test.createAccount()

access(all) let flowTokenIdentifier = "A.0000000000000003.FlowToken.Vault"
access(all) let moetTokenIdentifier = "A.0000000000000007.MOET.Vault"
access(all) let flowVaultStoragePath = /storage/flowTokenVault

access(all) let flowBorrowFactor = 1.0
access(all) let flowStartPrice = 1.0
access(all) let positionFundingAmount = 1_000.0

access(all) var snapshot: UInt64 = 0
access(all) var positionID: UInt64 = 0

access(all)
fun setup() {
    deployContracts()

    grantBetaPoolParticipantAccess(protocolAccount, protocolConsumerAccount)
    grantBetaPoolParticipantAccess(protocolAccount, userAccount)

    // Price setup
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: flowTokenIdentifier, price: flowStartPrice)
    setMockOraclePrice(signer: protocolAccount, forTokenIdentifier: moetTokenIdentifier, price: 1.0)

    // Create the Pool & add FLOW as supported token
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: moetTokenIdentifier, beFailed: false)
    addSupportedTokenZeroRateCurve(
        signer: protocolAccount,
        tokenTypeIdentifier: flowTokenIdentifier,
        collateralFactor: 0.65,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // Prep user's account
    setupMoetVault(userAccount, beFailed: false)
    mintFlow(to: userAccount, amount: positionFundingAmount * 2.0)

    snapshot = getCurrentBlockHeight()
}

access(all)
fun testRecursiveWithdrawSource() {
    // Ensure we always run from the same post-setup chain state.
    // This makes the test deterministic across multiple runs.
    if snapshot < getCurrentBlockHeight() {
        Test.reset(to: snapshot)
    }

    // -------------------------------------------------------------------------
    // Seed pool liquidity / establish a baseline lender position
    // -------------------------------------------------------------------------
    // Create a separate account (user1) that funds the pool by opening a position
    // with a large initial deposit. This ensures the pool has reserves available
    // for subsequent borrow/withdraw paths in this test.
    let user1 = Test.createAccount()
    setupMoetVault(user1, beFailed: false)
    mintMoet(signer: protocolAccount, to: user1.address, amount: 10000.0, beFailed: false)
    mintFlow(to: user1, amount: 10000.0)

    let initialDeposit1 = 10000.0
    createPosition(
        admin: PROTOCOL_ACCOUNT,
        signer: user1,
        amount: initialDeposit1,
        vaultStoragePath: /storage/flowTokenVault,
        pushToDrawDownSink: false
    )
    log("[TEST] USER1 POSITION ID: \(positionID)")

    // -------------------------------------------------------------------------
    // Attempt a reentrancy / recursive-withdraw scenario
    // -------------------------------------------------------------------------
    // Open a new position for `userAccount` using a special transaction that wires
    // a *malicious* topUpSource (or wrapper behavior) designed to attempt recursion
    // during `withdrawAndPull(..., pullFromTopUpSource: true)`.
    //
    // The goal is to prove the pool rejects the attempt (e.g. via position lock /
    // reentrancy guard), rather than allowing nested withdraw/deposit effects.
    let openRes = executeTransaction(
        "./transactions/position-manager/create_position_reentrancy.cdc",
        [positionFundingAmount, flowVaultStoragePath, false],
        userAccount
    )
    Test.expect(openRes, Test.beSucceeded())

    // Read the newly opened position id from the latest Opened event.
    var evts = Test.eventsOfType(Type<FlowALPv1.Opened>())
    let openedEvt = evts[evts.length - 1] as! FlowALPv1.Opened
    positionID = openedEvt.pid
    log("[TEST] Position opened with ID: \(positionID)")

    // Log balances for debugging context only (not assertions).
    let remainingFlow = getBalance(address: userAccount.address, vaultPublicPath: /public/flowTokenReceiver) ?? 0.0
    log("[TEST] User FLOW balance after open: \(remainingFlow)")
    let moetBalance = getBalance(address: userAccount.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0
    log("[TEST] User MOET balance after open: \(moetBalance)")

    // -------------------------------------------------------------------------
    // Trigger the vulnerable path: withdraw with pullFromTopUpSource=true
    // -------------------------------------------------------------------------
    // This withdrawal is intentionally oversized so it cannot be satisfied purely
    // from the position’s current available balance. The pool will attempt to pull
    // funds from the configured topUpSource to keep the position above minHealth.
    //
    // In this test, the topUpSource behavior is adversarial: it attempts to re-enter
    // the pool during the pull/deposit flow. We expect the transaction to fail.
    let withdrawRes = executeTransaction(
        "./transactions/flow-alp/pool-management/withdraw_from_position.cdc",
        [positionID, flowTokenIdentifier, 1500.0, true], // pullFromTopUpSource: true
        userAccount
    )
    Test.expect(withdrawRes, Test.beFailed())

    // Log post-failure balances for debugging context.
    let currentFlow = getBalance(address: userAccount.address, vaultPublicPath: /public/flowTokenReceiver) ?? 0.0
    log("[TEST] User FLOW balance after failed withdraw: \(currentFlow)")
    let currentMoet = getBalance(address: userAccount.address, vaultPublicPath: MOET.VaultPublicPath) ?? 0.0
    log("[TEST] User MOET balance after failed withdraw: \(currentMoet)")
}
