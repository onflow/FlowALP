import "FlowALP"

transaction(
    enabled: Bool
) {
    let pool: auth(FlowALP.EGovernance) &FlowALP.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALP.EGovernance) &FlowALP.Pool>(from: FlowALP.PoolStoragePath)
            ?? panic("Could not borrow Pool at \(FlowALP.PoolStoragePath)")
    }

    execute {
        self.pool.setDebugLogging(enabled)
    }
}


