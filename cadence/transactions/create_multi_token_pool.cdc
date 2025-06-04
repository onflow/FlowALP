import TidalProtocol from "TidalProtocol"

// Transaction to create a pool with multiple token types
transaction(tokenTypes: [Type], prices: [UFix64], collateralFactors: [UFix64], borrowFactors: [UFix64]) {
    prepare(signer: auth(SaveValue, IssueStorageCapabilityController, PublishCapability) &Account) {
        // Create oracle and set prices for all tokens
        let oracle = TidalProtocol.DummyPriceOracle(defaultToken: tokenTypes[0])
        
        var i = 0
        while i < tokenTypes.length {
            oracle.setPrice(token: tokenTypes[i], price: prices[i])
            i = i + 1
        }
        
        // Create pool
        let pool <- TidalProtocol.createPool(
            defaultToken: tokenTypes[0],
            priceOracle: oracle
        )
        
        // Add all token types
        i = 0
        while i < tokenTypes.length {
            pool.addSupportedToken(
                tokenType: tokenTypes[i],
                collateralFactor: collateralFactors[i],
                borrowFactor: borrowFactors[i],
                interestCurve: TidalProtocol.SimpleInterestCurve(),
                depositRate: 10000.0,
                depositCapacityCap: 1000000.0
            )
            i = i + 1
        }
        
        // Save pool
        signer.storage.save(<-pool, to: /storage/tidalProtocolPool)
        
        // Create and publish capability
        let poolCap = signer.capabilities.storage.issue<&TidalProtocol.Pool>(
            /storage/tidalProtocolPool
        )
        signer.capabilities.publish(poolCap, at: /public/tidalProtocolPool)
    }
} 