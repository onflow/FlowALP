import TidalProtocol from "TidalProtocol"

transaction(tokenType: Type, newPrice: UFix64) {
    prepare(signer: auth(Storage) &Account) {
        // Get the pool from storage
        let pool = signer.storage.borrow<auth(TidalProtocol.EPosition) &TidalProtocol.Pool>(
            from: /storage/tidalPool
        ) ?? panic("Could not borrow pool from storage")
        
        // Get the oracle and update price
        let oracle = pool.priceOracle as! TidalProtocol.DummyPriceOracle
        oracle.setPrice(token: tokenType, price: newPrice)
    }
} 