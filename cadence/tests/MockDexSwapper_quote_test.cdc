import Test

access(all)
fun test_mockdex_quote_math() {
    // Self-contained deploys: only what the mock quote test needs
    var err = Test.deployContract(
        name: "DeFiActionsUtils",
        path: "../../DeFiActions/cadence/contracts/utils/DeFiActionsUtils.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "DeFiActionsMathUtils",
        path: "../../DeFiActions/cadence/contracts/utils/DeFiActionsMathUtils.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "DeFiActions",
        path: "../../DeFiActions/cadence/contracts/interfaces/DeFiActions.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    let initialSupply = 0.0
    err = Test.deployContract(
        name: "MOET",
        path: "../contracts/MOET.cdc",
        arguments: [initialSupply]
    )
    Test.expect(err, Test.beNil())

    err = Test.deployContract(
        name: "MockDexSwapper",
        path: "../contracts/mocks/MockDexSwapper.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    // Use the canonical protocol account for simplicity
    let signer = Test.getAccount(0x0000000000000007)

    // Ensure MOET vault exists and fund it
    let setupRes = Test.Transaction(
        code: Test.readFile("../transactions/moet/setup_vault.cdc"),
        authorizers: [signer.address],
        signers: [signer],
        arguments: []
    )
    Test.expect(Test.executeTransaction(setupRes), Test.beSucceeded())

    let mintRes = Test.Transaction(
        code: Test.readFile("../transactions/moet/mint_moet.cdc"),
        authorizers: [signer.address],
        signers: [signer],
        arguments: [signer.address, 10_000.0]
    )
    Test.expect(Test.executeTransaction(mintRes), Test.beSucceeded())

    // Run the mock quote check harness
    let tx = Test.Transaction(
        code: Test.readFile("../transactions/mocks/dex/mockdex_quote_check.cdc"),
        authorizers: [signer.address],
        signers: [signer],
        arguments: [1.5, 300.0, 200.0]
    )
    let txRes = Test.executeTransaction(tx)
    Test.expect(txRes, Test.beSucceeded())
}
