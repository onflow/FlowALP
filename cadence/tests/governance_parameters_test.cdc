import Test

import "MOET"
import "test_helpers.cdc"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)

access(all)
fun setup() {
    deployContracts()
}

// -----------------------------------------------------------------------------
access(all)
fun test_setGovernanceParams_and_exercise_paths() {
    // Create pool
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)

    // 1) Exercise setInsuranceRate and negative-credit-rate branch
    // Set a relatively high insurance rate and construct a state with tiny debit income
    let setInsRes = _executeTransaction(
        "../transactions/tidal-protocol/pool-governance/set_insurance_rate.cdc",
        [ defaultTokenIdentifier, 0.50 ],
        protocolAccount
    )
    Test.expect(setInsRes, Test.beSucceeded())

    // Setup user and deposit small amount to create minimal credit, then call a read that triggers interest update via helper flows
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintMoet(signer: protocolAccount, to: user.address, amount: 10.0, beFailed: false)

    // Open minimal position and deposit to ensure token has credit balance
    grantPoolCapToConsumer()
    let flowVaultPath = /storage/flowTokenVault
    // Use existing integration test helper path to mint Flow via transaction
    let collateralAmount = 100.0
    let mintFlowRes = Test.executeTransaction(Test.Transaction(
        code: Test.readFile("../transactions/flowtoken/transfer_flowtoken.cdc"),
        authorizers: [Test.serviceAccount().address],
        signers: [Test.serviceAccount()],
        arguments: [user.address, collateralAmount]
    ))
    Test.expect(mintFlowRes, Test.beSucceeded())

    let openRes = _executeTransaction(
        "./transactions/mock-tidal-protocol-consumer/create_wrapped_position.cdc",
        [50.0, flowVaultPath, false],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // Trigger availableBalance which walks interest paths and ensures indices/rates get updated
    let _ = getAvailableBalance(pid: 0, vaultIdentifier: defaultTokenIdentifier, pullFromTopUpSource: false, beFailed: false)

    // 2) Exercise depositLimitFraction and queue branch
    // Set fraction small so a single deposit exceeds the per-deposit limit
    let setFracRes = _executeTransaction(
        "../transactions/tidal-protocol/pool-governance/set_deposit_limit_fraction.cdc",
        [ defaultTokenIdentifier, 0.05 ],
        protocolAccount
    )
    Test.expect(setFracRes, Test.beSucceeded())

    // Deposit a large amount to force queuing path
    mintMoet(signer: protocolAccount, to: user.address, amount: 1000.0, beFailed: false)
    let depositRes = _executeTransaction(
        "./transactions/mock-tidal-protocol-consumer/deposit_to_wrapped_position.cdc",
        [500.0, MOET.VaultStoragePath, false],
        user
    )
    Test.expect(depositRes, Test.beSucceeded())

    // 3) Exercise health accessors write/read
    let poolExistsRes = _executeScript("../scripts/tidal-protocol/pool_exists.cdc", [protocolAccount.address])
    Test.expect(poolExistsRes, Test.beSucceeded())

    // Use Position details to verify health is populated
    let posDetails = getPositionDetails(pid: 0, beFailed: false)
    Test.assert(posDetails.health > 0)
}


