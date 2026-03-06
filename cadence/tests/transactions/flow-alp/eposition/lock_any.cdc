import "FlowALPv0"
import "FlowALPModels"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Verifies that Capability<auth(EPosition) &Pool> grants:
///   Pool.lockPosition  — on ANY position
///   Pool.unlockPosition — on ANY position
///
/// EPosition allows pool-level position operations on any position by ID,
/// regardless of which account owns that position. No EParticipant required.
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
