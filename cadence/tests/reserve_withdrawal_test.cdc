import Test
import BlockchainHelpers

import "MOET"
import "test_helpers.cdc"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) let treasury = Test.createAccount()

access(all) var snapshot: UInt64 = 0

access(all)
fun setup() {
    deployContracts()
    
    // Take snapshot after setup
    snapshot = getCurrentBlockHeight()
}

access(all)
fun testReserveWithdrawalGovernanceControlled() {
    // create pool
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)
    // Must be deployed after the Pool is created
    var err = Test.deployContract(
        name: "FlowCreditMarketRegistry",
        path: "../contracts/FlowCreditMarketRegistry.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    // Setup MOET vault for treasury account
    setupMoetVault(treasury, beFailed: false)

    // accrue some reserve by minting MOET directly to reserve storage (placeholder)
    // TODO once contract exposes direct mint-to-reserve path; skipping balance assertion

    // non-governance account attempts withdrawal and should fail
    let attacker = Test.createAccount()
    setupMoetVault(attacker, beFailed: false)
    
    withdrawReserve(
        signer: attacker,
        poolAddress: protocolAccount.address,
        tokenTypeIdentifier: defaultTokenIdentifier,
        amount: 10.0,
        recipient: attacker.address,
        beFailed: true
    )

    // governance admin performs withdrawal → expect success
    withdrawReserve(
        signer: protocolAccount,
        poolAddress: protocolAccount.address,
        tokenTypeIdentifier: defaultTokenIdentifier,
        amount: 10.0,
        recipient: treasury.address,
        beFailed: false
    )
} 