import TidalProtocol from "TidalProtocol"

transaction() {
    prepare(signer: auth(Storage) &Account) {
        // Get the pool reference from storage
        let pool = signer.storage.borrow<auth(TidalProtocol.EPosition) &TidalProtocol.Pool>(
            from: /storage/testPool
        ) ?? panic("Could not borrow Pool reference")
        
        // Create a new position
        let positionID = pool.createPosition()
        
        // Log the position ID for reference
        log("Created position with ID: ".concat(positionID.toString()))
    }
} 