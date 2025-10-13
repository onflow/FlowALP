import Test

import "test_helpers.cdc"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)

access(all)
fun setup() {
    deployContracts()
}

// -----------------------------------------------------------------------------
access(all)
fun test_setInsuranceRate_and_depositLimitFraction_succeed() {
    // Create pool
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)

    // Update insurance rate to 0.2% for default token
    let setInsRes = _executeTransaction(
        "../transactions/tidal-protocol/pool-governance/set_insurance_rate.cdc",
        [ defaultTokenIdentifier, 0.002 ],
        protocolAccount
    )
    Test.expect(setInsRes, Test.beSucceeded())

    // Update deposit limit fraction to 10% for default token
    let setFracRes = _executeTransaction(
        "../transactions/tidal-protocol/pool-governance/set_deposit_limit_fraction.cdc",
        [ defaultTokenIdentifier, 0.10 ],
        protocolAccount
    )
    Test.expect(setFracRes, Test.beSucceeded())

    // Explicitly toggle debug logging (should already be enabled by helper)
    let setDebugRes = _executeTransaction(
        "../transactions/tidal-protocol/pool-governance/set_debug_logging.cdc",
        [ true ],
        protocolAccount
    )
    Test.expect(setDebugRes, Test.beSucceeded())
}


