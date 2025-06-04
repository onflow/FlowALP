import TidalProtocol from "TidalProtocol"

transaction() {
    prepare(signer: auth(SaveValue, IssueStorageCapabilityController, PublishCapability) &Account) {
        // Create a dummy oracle with String type as default token for testing
        let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
        oracle.setPrice(token: Type<String>(), price: 1.0)
        
        // Create pool with oracle
        let pool <- TidalProtocol.createPool(
            defaultToken: Type<String>(),
            priceOracle: oracle
        )
        
        // Add the default token to the pool
        pool.addSupportedToken(
            tokenType: Type<String>(),
            collateralFactor: 0.8,
            borrowFactor: 1.2,
            interestCurve: TidalProtocol.SimpleInterestCurve(),
            depositRate: 10000.0,
            depositCapacityCap: 1000000.0
        )
        
        // Store the pool in the account
        signer.storage.save(<-pool, to: /storage/tidalPool)
        
        // Create and publish capability
        let poolCap = signer.capabilities.storage.issue<&TidalProtocol.Pool>(
            /storage/tidalPool
        )
        signer.capabilities.publish(poolCap, at: /public/tidalPool)
    }
} 