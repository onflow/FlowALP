import TidalProtocol from "TidalProtocol"

transaction {
    prepare(signer: auth(Storage) &Account) {
        // Create a simple pool for testing
        let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
        let pool <- TidalProtocol.createTestPoolWithOracle(defaultToken: Type<String>())
        
        // Create a position
        let positionId = pool.createPosition()
        
        // Verify position was created
        let health = pool.positionHealth(pid: positionId)
        assert(health == 1.0, message: "Initial health should be 1.0")
        
        // Clean up
        destroy pool
    }
} 