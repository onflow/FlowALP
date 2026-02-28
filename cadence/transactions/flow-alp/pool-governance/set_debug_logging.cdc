import "FlowALPv0"

transaction(
    enabled: Bool
) {
    let pool: auth(FlowALPv0.EGovernance) &FlowALPv0.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALPv0.EGovernance) &FlowALPv0.Pool>(from: FlowALPv0.PoolStoragePath)
            ?? panic("Could not borrow Pool at \(FlowALPv0.PoolStoragePath)")
    }

    execute {
        self.pool.setDebugLogging(enabled)
    }
}


