import "FlowALPv0"

/// TEST-ONLY: Pause or unpause the pool.
///
/// This transaction exists solely for **testing purposes** to validate
/// failure scenarios and invariants around pausing.
/// It MUST NOT be used as a reference for production or governance flows.
///
/// @param pause: whether to pause or unpause the pool
transaction(pause: Bool) {
    let pool: auth(FlowALPv0.EGovernance) &FlowALPv0.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALPv0.EGovernance) &FlowALPv0.Pool>(from: FlowALPv0.PoolStoragePath)
            ?? panic("Could not borrow Pool at \(FlowALPv0.PoolStoragePath)")
    }

    execute {
        if (pause) {
            self.pool.borrowConfig().setPaused(true)
        } else {
            self.pool.unpausePool()
        }
    }
}
