import Test
import "test_helpers.cdc"
import "FlowCreditMarket"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)
access(all) let alice = Test.createAccount()

access(all)
fun setup() {
    deployContracts()

    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)
}

// ============================================================
// Access Control Tests
// ============================================================

// testSetInsuranceRate_WithoutEGovernanceEntitlement verifies if account without EGovernance entitlement can set insurance rate.
access(all) fun testSetInsuranceRate_WithoutEGovernanceEntitlement() {
    let newRate = 0.01
    
    let txResult = _executeTransaction(
        "../transactions/flow-credit-market/pool-governance/set_insurance_rate.cdc",
        [defaultTokenIdentifier, newRate],
        alice
    )
    
    // should fail due to missing EGovernance entitlement
    Test.expect(txResult, Test.beFailed())
}

// testSetInsuranceRate_RequiresEGovernanceEntitlement verifies the function requires proper EGovernance entitlement.
access(all) fun testSetInsuranceRate_WithEGovernanceEntitlement() {
    let newRate = 0.01
    
    // use protocol account with proper entitlement
    let txResult = _executeTransaction(
        "../transactions/flow-credit-market/pool-governance/set_insurance_rate.cdc",
        [defaultTokenIdentifier, newRate],
        protocolAccount
    )

    Test.expect(txResult, Test.beSucceeded())
}

// ============================================================
// Boundary Tests: insuranceRate must be between 0 and 1
// ============================================================

access(all) fun testSetInsuranceRate_RateGreaterThanOne_Fails() {
    // rate > 1.0 violates precondition
    let invalidRate = 1.01
    
    let txResult = _executeTransaction(
        "../transactions/flow-credit-market/pool-governance/set_insurance_rate.cdc",
        [defaultTokenIdentifier, invalidRate],
        protocolAccount
    )
    
    // should fail with "insuranceRate must be between 0 and 1"
    Test.expect(txResult, Test.beFailed())

    let errorMessage = txResult.error!.message
    let containsExpectedError = errorMessage.contains("insuranceRate must be between 0 and 1")
    Test.assert(containsExpectedError, message: "expected error about insurance rate bounds,got: \(errorMessage)")
}


access(all) fun testSetInsuranceRate_RateLessThanZero_Fails() {
    // rate < 0
    let invalidRate = -0.01
    
    let txResult = _executeTransaction(
        "../transactions/flow-credit-market/pool-governance/set_insurance_rate.cdc",
        [defaultTokenIdentifier, invalidRate],
        protocolAccount
    )
    
    // should fail with "expected value of type UFix64"
    Test.expect(txResult, Test.beFailed())

    let errorMessage = txResult.error!.message
    let containsExpectedError = errorMessage.contains("invalid argument at index 1: expected value of type `UFix64`")
    Test.assert(containsExpectedError, message: "expected error about insurance rate bounds,got: \(errorMessage)")
}

// ============================================================
// Token Type Tests
// ============================================================

access(all) fun testSetInsuranceRate_InvalidTokenType_Fails() {
    let invalidTokenIdentifier = "InvalidTokenType"
    let newRate = 0.05
    
    let txResult = _executeTransaction(
        "../transactions/flow-credit-market/pool-governance/set_insurance_rate.cdc",
        [invalidTokenIdentifier, newRate],
        protocolAccount
    )
    
    // should fail with "Invalid tokenTypeIdentifier"
    Test.expect(txResult, Test.beFailed())

    let errorMessage = txResult.error!.message
    let containsExpectedError = errorMessage.contains("Invalid tokenTypeIdentifier")
    Test.assert(containsExpectedError, message: "expected error about insurance rate bounds,got: \(errorMessage)")
}