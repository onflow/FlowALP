import TidalProtocol from "../contracts/TidalProtocol.cdc"

transaction(defaultTokenIdentifier: String, oracleAddress: Address, depositRate: UFix64, depositCapacityCap: UFix64) {
    prepare(signer: auth(BorrowValue, SaveValue) &Account) {
        // Get the oracle reference
        let oracle = getAccount(oracleAddress).capabilities.borrow<&{TidalProtocol.PriceOracle}>(
            /public/DummyPriceOracle
        ) ?? panic("Could not borrow oracle reference")

        // Parse the token type
        let defaultTokenType = CompositeType(defaultTokenIdentifier) 
            ?? panic("Invalid token type identifier")

        // Create the pool with oracle
        let pool <- TidalProtocol.createPool(
            defaultToken: defaultTokenType,
            priceOracle: oracle
        )

        // Add the default token with rate limiting parameters
        pool.addSupportedToken(
            tokenType: defaultTokenType,
            collateralFactor: 1.0,
            borrowFactor: 1.0,
            interestCurve: TidalProtocol.SimpleInterestCurve(),
            depositRate: depositRate,
            depositCapacityCap: depositCapacityCap
        )

        // Save the pool to storage
        signer.storage.save(<-pool, to: /storage/tidalPool)

        // Create capabilities
        let poolCap = signer.capabilities.storage.issue<&TidalProtocol.Pool>(
            /storage/tidalPool
        )
        signer.capabilities.publish(poolCap, at: /public/tidalPool)

        let authPoolCap = signer.capabilities.storage.issue<auth(TidalProtocol.EPosition) &TidalProtocol.Pool>(
            /storage/tidalPool
        )
        signer.capabilities.publish(authPoolCap, at: /private/tidalPoolAuth)
    }
} 