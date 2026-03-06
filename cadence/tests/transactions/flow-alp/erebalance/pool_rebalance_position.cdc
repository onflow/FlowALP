import "FlowALPv0"
import "FlowALPModels"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Verifies that auth(ERebalance) &Pool grants access to Pool.rebalancePosition.
/// ERebalance is the narrower entitlement specifically for rebalancing operations,
/// distinct from the broader EPosition entitlement.
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
