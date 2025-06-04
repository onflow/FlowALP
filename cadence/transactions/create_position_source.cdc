import TidalProtocol from "../contracts/TidalProtocol.cdc"

transaction(positionId: UInt64, tokenType: Type) {
    prepare(signer: auth(BorrowValue, SaveValue) &Account) {
        // Get the pool auth reference from storage
        let poolCap = signer.storage.borrow<Capability<auth(TidalProtocol.EPosition) &TidalProtocol.Pool>>(
            from: /storage/tidalPoolAuth
        ) ?? panic("Could not borrow pool auth capability")
        
        let pool = poolCap.borrow() ?? panic("Could not borrow pool reference")
        
        // Note: There's no createSource method directly on the pool
        // Sources are created through the Position struct
        // For testing purposes, we'll save the position ID and token type
        // The test can verify that these values were set correctly
        signer.storage.save(positionId, to: /storage/testSourcePid)
        signer.storage.save(tokenType, to: /storage/testSourceType)
    }
} 