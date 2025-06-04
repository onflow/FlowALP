import TidalProtocol from "../contracts/TidalProtocol.cdc"

transaction(poolAddress: Address, positionId: UInt64, tokenType: String) {
    prepare(signer: auth(BorrowValue, SaveValue) &Account) {
        // Get the pool reference
        let pool = getAccount(poolAddress).capabilities.borrow<auth(TidalProtocol.EPosition) &TidalProtocol.Pool>(
            /private/tidalPoolAuth
        ) ?? panic("Could not borrow pool reference")

        // Parse the token type
        let vaultType = CompositeType(tokenType) 
            ?? panic("Invalid token type identifier")

        // Create a position sink
        let sink <- pool.createSink(
            pid: positionId,
            tokenType: vaultType
        )

        // Save the sink to storage
        let storagePath = StoragePath(identifier: "tidalPositionSink")!
        signer.storage.save(<-sink, to: storagePath)

        // Create and publish capability
        let sinkCap = signer.capabilities.storage.issue<&{TidalProtocol.PositionSink}>(
            storagePath
        )
        let publicPath = PublicPath(identifier: "tidalPositionSink")!
        signer.capabilities.publish(sinkCap, at: publicPath)
    }
} 