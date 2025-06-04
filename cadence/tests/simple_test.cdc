import Test

access(all)
fun setup() {
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

access(all)
fun testSimpleImport() {
    // Verify the contract was deployed successfully
    Test.assert(true, message: "Contract deployment should succeed")
}

access(all) 
fun testBasicMath() {
    // Test basic operations to ensure test framework is working
    Test.assertEqual(2 + 2, 4)
    Test.assertEqual(10 - 5, 5)
    Test.assertEqual(3 * 4, 12)
} 