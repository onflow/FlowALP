import "FlowALPv0"
import "FlowALPModels"

/// TEST-ONLY: Pause or unpause the pool.
///
/// This transaction exists solely for **testing purposes** to validate
/// failure scenarios and invariants around pausing.
/// It MUST NOT be used as a reference for production or governance flows.
///
/// @param pause: whether to pause or unpause the pool
transaction(pause: Bool) {
    let pool: auth(FlowALPModels.EGovernance) &FlowALPv0.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        let cap = signer.storage.borrow<&Capability<auth(FlowALPModels.EGovernance) &FlowALPv0.Pool>>(
            from: FlowALPv0.PoolCapStoragePath
        ) ?? panic("No EGovernance cap found")
        self.pool = cap.borrow() ?? panic("Could not borrow Pool from EGovernance cap")
    }

    execute {
        if (pause) {
            self.pool.pausePool()
        } else {
            self.pool.unpausePool()
        }
    }
}
