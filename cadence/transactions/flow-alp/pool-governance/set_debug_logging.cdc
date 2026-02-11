import "FlowALPv1"

transaction(
    enabled: Bool
) {
    let pool: auth(FlowALPv1.EGovernance) &FlowALPv1.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALPv1.EGovernance) &FlowALPv1.Pool>(from: FlowALPv1.PoolStoragePath)
            ?? panic("Could not borrow Pool at \(FlowALPv1.PoolStoragePath)")
    }

    execute {
        self.pool.setDebugLogging(enabled)
    }
}


