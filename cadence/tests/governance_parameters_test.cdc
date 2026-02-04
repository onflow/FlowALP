import Test

import "MOET"
import "test_helpers.cdc"

access(all)
fun setup() {
    deployContracts()
}

// -----------------------------------------------------------------------------
access(all)
fun test_setGovernanceParams_and_exercise_paths() {
    // Create pool
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    
    // 1) Set insurance swapper
    let res = setInsuranceSwapper(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        priceRatio: 1.0,
    )
    Test.expect(res, Test.beSucceeded())

    // 2) Exercise setInsuranceRate and negative-credit-rate branch
    // Set a relatively high insurance rate and construct a state with tiny debit income
    let setInsRes = setInsuranceRate(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOET_TOKEN_IDENTIFIER,
        insuranceRate: 0.50,
    )
    Test.expect(setInsRes, Test.beSucceeded())

    // Setup user and deposit small amount to create minimal credit, then call a read that triggers interest update via helper flows
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintMoet(signer: PROTOCOL_ACCOUNT, to: user.address, amount: 200.0, beFailed: false)

    // Open minimal position and deposit to ensure token has credit balance
    let openRes = _executeTransaction(
        "../transactions/flow-credit-market/position/create_position.cdc",
        [50.0, MOET.VaultStoragePath, false],
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // Trigger availableBalance which walks interest paths and ensures indices/rates get updated
    let _ = getAvailableBalance(pid: 0, vaultIdentifier: MOET_TOKEN_IDENTIFIER, pullFromTopUpSource: false, beFailed: false)

    // 3) Exercise depositLimitFraction and queue branch
    // Set fraction small so a single deposit exceeds the per-deposit limit
    let setFracRes = _executeTransaction(
        "../transactions/flow-credit-market/pool-governance/set_deposit_limit_fraction.cdc",
        [ MOET_TOKEN_IDENTIFIER, 0.05 ],
        PROTOCOL_ACCOUNT
    )
    Test.expect(setFracRes, Test.beSucceeded())

    // Deposit a large amount to force queuing path
    mintMoet(signer: PROTOCOL_ACCOUNT, to: user.address, amount: 1000.0, beFailed: false)
    let depositRes = _executeTransaction(
        "./transactions/position-manager/deposit_to_position.cdc",
        [UInt64(0), 500.0, MOET.VaultStoragePath, false],
        user
    )
    Test.expect(depositRes, Test.beSucceeded())

    // 4) Exercise health accessors write/read
    let poolExistsRes = _executeScript("../scripts/flow-credit-market/pool_exists.cdc", [PROTOCOL_ACCOUNT.address])
    Test.expect(poolExistsRes, Test.beSucceeded())

    // Use Position details to verify health is populated
    let posDetails = getPositionDetails(pid: 0, beFailed: false)
    Test.assert(posDetails.health > 0.0)
}


