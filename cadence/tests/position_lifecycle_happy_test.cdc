import Test
import BlockchainHelpers

import "MOET"
import "FlowALPv1"
import "test_helpers.cdc"

// -----------------------------------------------------------------------------
// Position Lifecycle Happy Path Test
// -----------------------------------------------------------------------------

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()

    snapshot = getCurrentBlockHeight()
}

// -----------------------------------------------------------------------------
access(all)
fun testPositionLifecycleHappyPath() {
    // Test.reset(to: snapshot)

    // price setup
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)

    // create pool & enable token
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // user prep
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintFlow(to: user, amount: 1_000.0)

    // Grant beta access to user so they can create positions
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    let balanceBefore = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    Test.assertEqual(0.0, balanceBefore)

    // open wrapped position (pushToDrawDownSink)
    let openRes = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [1_000.0, FLOW_VAULT_STORAGE_PATH, true],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // confirm position open and user borrowed MOET
    let balanceAfterBorrow = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    Test.assert(balanceAfterBorrow > 0.0)
    
    // Verify specific borrowed amount: 
    // With 1000 Flow at 0.8 collateral factor = 800 effective collateral
    // Target health 1.3 means: effective debt = 800 / 1.3 ≈ 615.38
    let expectedBorrowAmount = 615.38461538
    Test.assert(balanceAfterBorrow >= expectedBorrowAmount - 0.01 && 
                balanceAfterBorrow <= expectedBorrowAmount + 0.01,
                message: "Expected MOET balance to be ~615.38, but got ".concat(balanceAfterBorrow.toString()))

    // Check Flow balance before repayment
    let flowBalanceBefore = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    log("Flow balance BEFORE repay: ".concat(flowBalanceBefore.toString()))

    // repay MOET and close position
    // The first position created has ID 0
    let positionId: UInt64 = 0
    let repayRes = executeTransaction(
        "../transactions/flow-alp/position/repay_and_close_position.cdc",
        [positionId],
        user
    )
    Test.expect(repayRes, Test.beSucceeded())

    // After repayment, user MOET balance should be 0
    let balanceAfterRepay = getBalance(address: user.address, vaultPublicPath: MOET.VaultPublicPath)!
    Test.assertEqual(0.0, balanceAfterRepay)

    let flowBalanceAfter = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    log("Flow balance after repay: ".concat(flowBalanceAfter.toString()).concat(" - Collateral successfully returned!"))
    Test.assert(flowBalanceAfter >= 999.99)  // allow tiny rounding diff
} 
