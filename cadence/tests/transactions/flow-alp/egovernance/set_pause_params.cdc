import "FlowALPv0"
import "FlowALPModels"

/// Sets the pool pause warmup period via Pool.borrowConfig.
/// Requires an EGovernance capability at PoolCapStoragePath.
///
/// @param warmupSec: Warm-up period in seconds before pause takes full effect
transaction(warmupSec: UInt64) {
    let pool: auth(FlowALPModels.EGovernance) &FlowALPv0.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        let cap = signer.storage.borrow<&Capability<auth(FlowALPModels.EGovernance) &FlowALPv0.Pool>>(
            from: FlowALPv0.PoolCapStoragePath
        ) ?? panic("No EGovernance cap found")
        self.pool = cap.borrow() ?? panic("Could not borrow Pool from EGovernance cap")
    }

    execute {
        self.pool.borrowConfig().setWarmupSec(warmupSec)
    }
}
