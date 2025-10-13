import "TidalProtocol"

transaction(
    enabled: Bool
) {
    let pool: auth(TidalProtocol.EGovernance) &TidalProtocol.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(TidalProtocol.EGovernance) &TidalProtocol.Pool>(from: TidalProtocol.PoolStoragePath)
            ?? panic("Could not borrow Pool at \(TidalProtocol.PoolStoragePath)")
    }

    execute {
        self.pool.setDebugLogging(enabled)
    }
}


