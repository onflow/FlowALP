import Test
import BlockchainHelpers
import "test_helpers.cdc"
import "FlowALPv1"
import "MOET"
import "FlowToken"
import "FlowALPMath"

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

    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    grantPoolCapToConsumer()
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    snapshot = getCurrentBlockHeight()
}

access(all)
fun test_borrower_full_redemption_insolvency() {
    safeReset()
    let pid: UInt64 = 0

    // Borrower setup
    let borrower = Test.createAccount()
    setupMoetVault(borrower, beFailed: false)
    transferFlowTokens(to: borrower, amount: 1000.0)

    // Open wrapped position and deposit Flow as collateral
    let openRes = _executeTransaction(
        "./transactions/mock-flow-alp-consumer/create_wrapped_position.cdc",
        [1000.0, /storage/flowTokenVault, true],
        borrower
    )
    Test.expect(openRes, Test.beSucceeded())

    // Force insolvency (HF < 1.0)
    setMockOraclePrice(signer: Test.getAccount(0x0000000000000007), forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 0.6)
    let hAfter = getPositionHealth(pid: pid, beFailed: false)
    Test.assert(FlowALPMath.toUFix64Round(hAfter) < 1.0, message: "Expected HF < 1.0 after price drop")

    // Inspect position to get MOET debt
    let details = getPositionDetails(pid: pid, beFailed: false)
    var moetDebt: UFix64 = 0.0
    for b in details.balances {
        if b.vaultType == Type<@MOET.Vault>() && b.direction == FlowALPv1.BalanceDirection.Debit {
            moetDebt = b.balance
        }
    }
    Test.assert(moetDebt > 0.0, message: "Expected non-zero MOET debt")

    // Ensure borrower has enough MOET to repay entire debt via topUpSource pull
    _executeTransaction("../transactions/moet/mint_moet.cdc", [borrower.address, moetDebt + 0.000001], Test.getAccount(0x0000000000000007))

    // Execute borrower redemption: repay MOET (pulled from topUpSource) and withdraw Flow up to availableBalance
    // Note: use the helper tx which withdraws availableBalance with pullFromTopUpSource=true
    let closeRes = _executeTransaction(
        "./transactions/flow-alp/pool-management/repay_and_close_position.cdc",
        [/storage/flowALPv1PositionWrapper],
        borrower
    )
    Test.expect(closeRes, Test.beSucceeded())

    // Post-conditions: zero debt, collateral redeemed, HF == ceiling
    let detailsAfter = getPositionDetails(pid: pid, beFailed: false)
    var postMoetDebt: UFix64 = 0.0
    var postFlowColl: UFix64 = 0.0
    for b in detailsAfter.balances {
        if b.vaultType == Type<@MOET.Vault>() && b.direction == FlowALPv1.BalanceDirection.Debit { postMoetDebt = b.balance }
        if b.vaultType == Type<@FlowToken.Vault>() && b.direction == FlowALPv1.BalanceDirection.Credit { postFlowColl = b.balance }
    }
    Test.assertEqual(0.0, postMoetDebt)
    Test.assertEqual(0.0, postFlowColl)

    let hFinal = getPositionHealth(pid: pid, beFailed: false)
    Test.assertEqual(CEILING_HEALTH, hFinal)
}


