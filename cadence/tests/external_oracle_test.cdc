#test_fork(network: "mainnet", height: nil)

import Test

import "FlowToken"
import "MOET"
import "EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750" // PYUSD0

access(all) let PYUSD0VaultType = Type<@EVMVMBridgedToken_99af3eea856556646c98c8b9b2548fe815240750.Vault>()

access(all) fun setup() {
    var err: Test.Error? = nil

    // TODO(holyfuchs):
    // remove this once this is deployed to mainnet: holyfuchs/incrementfi-price-oracle
    err = Test.deployContract(
        name: "IncrementFiSwapConnectors",
        path: "../../FlowActions/cadence/contracts/connectors/increment-fi/IncrementFiSwapConnectors.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
}

access(all) fun test_band() {
    let feeAccount = Test.createAccount()
    let txn = Test.Transaction(
        code: Test.readFile("transactions/external_oracle/create_band_empty_fee.cdc"),
        authorizers: [feeAccount.address],
        signers: [feeAccount],
        arguments: [Type<@MOET.Vault>()]
    )
    let result = Test.executeTransaction(txn)
    Test.expect(result, Test.beSucceeded())

    let unitScriptResult = Test.executeScript(
        Test.readFile("scripts/external_oracle/band_unit_of_account.cdc"),
        [feeAccount.address]
    )
    Test.expect(unitScriptResult, Test.beSucceeded())
    let unitId = unitScriptResult.returnValue! as! String?
    log(unitId)
    Test.assert(unitId != nil, message: "expected unitOfAccount identifier")
    Test.assert(unitId!.length > 0, message: "expected non-empty unitOfAccount")
}

access(all) fun test_band_price() {
    let feeAccount = Test.createAccount()
    let txn = Test.Transaction(
        code: Test.readFile("transactions/external_oracle/create_band_empty_fee.cdc"),
        authorizers: [feeAccount.address],
        signers: [feeAccount],
        arguments: [Type<@MOET.Vault>()]
    )
    Test.expect(Test.executeTransaction(txn), Test.beSucceeded())

    let priceScriptResult = Test.executeScript(
        Test.readFile("scripts/external_oracle/band_price.cdc"),
        [feeAccount.address, Type<@FlowToken.Vault>()]
    )
    Test.expect(priceScriptResult, Test.beSucceeded())
    let price = priceScriptResult.returnValue as! UFix64?
    log(price)
    Test.assert(price != nil, message: "expected price, got nil")
}

access(all) fun test_increment_fi() {
    let flowKey = String.join(Type<@FlowToken.Vault>().identifier.split(separator: ".").slice(from: 0, upTo: 3), separator: ".")
    let moetKey = String.join(Type<@MOET.Vault>().identifier.split(separator: ".").slice(from: 0, upTo: 3), separator: ".")
    let path = [flowKey, moetKey]
    let unitScriptResult = Test.executeScript(
        Test.readFile("scripts/external_oracle/increment_fi_unit_of_account.cdc"),
        [Type<@MOET.Vault>(), Type<@FlowToken.Vault>(), path]
    )
    Test.expect(unitScriptResult, Test.beSucceeded())
    let unitId = unitScriptResult.returnValue! as! String?
    Test.assert(unitId != nil, message: "expected unitOfAccount identifier")
    Test.assert(unitId!.length > 0, message: "expected non-empty unitOfAccount")
}

access(all) fun test_increment_fi_price() {
    let flowKey = String.join(Type<@FlowToken.Vault>().identifier.split(separator: ".").slice(from: 0, upTo: 3), separator: ".")
    let pyusd0Key = String.join(PYUSD0VaultType.identifier.split(separator: ".").slice(from: 0, upTo: 3), separator: ".")
    let path = [flowKey, pyusd0Key]
    let priceScriptResult = Test.executeScript(
        Test.readFile("scripts/external_oracle/increment_fi_price.cdc"),
        [PYUSD0VaultType, Type<@FlowToken.Vault>(), path]
    )
    Test.expect(priceScriptResult, Test.beSucceeded())
    let price = priceScriptResult.returnValue as! UFix64?
    log(price)
    Test.assert(price != nil, message: "expected price when pair exists")
}

