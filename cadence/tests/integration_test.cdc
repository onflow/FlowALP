import Test

access(all) let account = Test.getAccount(0x0000000000000007)

access(all) fun setup() {
    // Deploy DFB first since TidalProtocol imports it
    var err = Test.deployContract(
        name: "DFB",
        path: "../../DeFiBlocks/cadence/contracts/interfaces/DFB.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    // Deploy MOET before TidalProtocol since TidalProtocol imports it
    err = Test.deployContract(
        name: "MOET",
        path: "../contracts/MOET.cdc",
        arguments: [1000000.0]  // Initial supply
    )
    Test.expect(err, Test.beNil())
    
    // Deploy TidalProtocol
    err = Test.deployContract(
        name: "TidalProtocol",
        path: "../contracts/TidalProtocol.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
}

access(all) fun testContractDeployment() {
    // Test that the contract deployed successfully by checking if we can import it
    let code = "import TidalProtocol from 0x0000000000000007; access(all) fun main(): Bool { return true }"
    
    let result = Test.executeScript(code, [])
    Test.expect(result, Test.beSucceeded())
}

access(all) fun testBasicPoolOperations() {
    // Test basic pool operations through transaction
    let code = Test.readFile("../transactions/test_basic_pool.cdc")
    let tx = Test.Transaction(
        code: code,
        authorizers: [account.address],
        signers: [account],
        arguments: []
    )
    
    let result = Test.executeTransaction(tx)
    Test.expect(result, Test.beSucceeded())
}

access(all) fun testHealthCalculations() {
    // Test health calculations through script
    let code = Test.readFile("../scripts/test_health_calc.cdc")
    let result = Test.executeScript(code, [])
    
    Test.expect(result, Test.beSucceeded())
    
    if let returnValue = result.returnValue {
        Test.assertEqual(true, returnValue as! Bool)
    }
}

access(all) fun testAccessControlInPractice() {
    // Test access control through practical usage
    let code = Test.readFile("../scripts/test_access_practical.cdc")
    let result = Test.executeScript(code, [])
    
    Test.expect(result, Test.beSucceeded())
    
    if let returnValue = result.returnValue {
        Test.assertEqual(true, returnValue as! Bool)
    }
} 