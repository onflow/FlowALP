import "FlowALPv0"
import "FlowALPModels"

/// Rebalances a position via a direct ERebalance borrow from PoolStoragePath.
/// Uses the narrow ERebalance entitlement — distinct from the broader EPosition.
///
/// @param pid:   The position ID to rebalance
/// @param force: Whether to force rebalance regardless of health bounds
transaction(pid: UInt64, force: Bool) {
    let pool: auth(FlowALPModels.ERebalance) &FlowALPv0.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALPModels.ERebalance) &FlowALPv0.Pool>(from: FlowALPv0.PoolStoragePath)
            ?? panic("Could not borrow Pool with ERebalance entitlement")
    }

    execute {
        self.pool.rebalancePosition(pid: pid, force: force)
    }
}
