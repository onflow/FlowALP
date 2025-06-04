import Test
import "TidalProtocol"

access(all)
fun setup() {
    // Deploy contracts directly
    var err = Test.deployContract(
        name: "DFB",
        path: "../../DeFiBlocks/cadence/contracts/interfaces/DFB.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    err = Test.deployContract(
        name: "MOET",
        path: "../contracts/MOET.cdc",
        arguments: [1000000.0]
    )
    Test.expect(err, Test.beNil())
    
    err = Test.deployContract(
        name: "TidalProtocol",
        path: "../contracts/TidalProtocol.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
}

// F-series: Reserve management

access(all)
fun testReserveBalanceTracking() {
    /* 
     * Test F-1: Reserve balance tracking
     * 
     * Test pool reserve management functionality
     */
    
    // Create pool with oracle
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    var pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // Initial reserve should be 0
    let initialReserve = pool.reserveBalance(type: Type<String>())
    Test.assertEqual(0.0, initialReserve)
    
    // Create multiple positions
    let pid1 = pool.createPosition()
    let pid2 = pool.createPosition()
    
    // Check positions are created with sequential IDs
    Test.assertEqual(UInt64(0), pid1)
    Test.assertEqual(UInt64(1), pid2)
    
    // Both positions should be healthy (no debt)
    Test.assertEqual(1.0, pool.positionHealth(pid: pid1))
    Test.assertEqual(1.0, pool.positionHealth(pid: pid2))
    
    // Clean up
    destroy pool
}

access(all)
fun testMultiplePositions() {
    /* 
     * Test F-2: Multiple positions
     * 
     * Create multiple positions in same pool
     * Each position tracked independently
     */
    
    // Create pool with oracle
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    var pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // Create three different positions
    let positions: [UInt64] = []
    positions.append(pool.createPosition())
    positions.append(pool.createPosition())
    positions.append(pool.createPosition())
    
    // Verify all positions created
    Test.assertEqual(3, positions.length)
    
    // Each position should have independent health
    for pid in positions {
        let health = pool.positionHealth(pid: pid)
        Test.assertEqual(1.0, health)
        
        let details = pool.getPositionDetails(pid: pid)
        Test.assertEqual(0, details.balances.length)
        Test.assertEqual(Type<String>(), details.poolDefaultToken)
    }
    
    // Clean up
    destroy pool
}

access(all)
fun testPositionIDGeneration() {
    /* 
     * Test F-3: Position ID generation
     * 
     * Create multiple positions
     * IDs increment sequentially from 0
     */
    
    // Create pool with oracle
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    var pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // Create positions and verify sequential IDs
    let expectedIDs: [UInt64] = [0, 1, 2, 3, 4]
    let actualIDs: [UInt64] = []
    
    for _ in expectedIDs {
        let pid = pool.createPosition()
        actualIDs.append(pid)
    }
    
    // Verify IDs match expected sequence
    var index = 0
    for expectedID in expectedIDs {
        Test.assertEqual(expectedID, actualIDs[index])
        index = index + 1
    }
    
    // Clean up
    destroy pool
} 