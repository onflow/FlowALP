import "FlowALPv0"
import "FlowALPModels"

/// Locks then unlocks any position via an EPosition capability at PoolCapStoragePath.
/// EPosition allows operations on any position by ID, regardless of ownership.
///
/// @param pid: Target position ID (may belong to a different account)
transaction(pid: UInt64) {
    let pool: auth(FlowALPModels.EPosition) &FlowALPv0.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        let cap = signer.storage.borrow<&Capability<auth(FlowALPModels.EPosition) &FlowALPv0.Pool>>(
            from: FlowALPv0.PoolCapStoragePath
        ) ?? panic("EPosition capability not found")
        self.pool = cap.borrow() ?? panic("Could not borrow Pool with EPosition")
    }

    execute {
        self.pool.lockPosition(pid)
        self.pool.unlockPosition(pid)
    }
}
