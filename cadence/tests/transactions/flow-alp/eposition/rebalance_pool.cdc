import "FlowALPv0"
import "FlowALPModels"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Verifies that Capability<auth(EPosition) &Pool> grants access to
/// Pool.rebalancePosition via the EPosition entitlement.
///
/// ePositionUser holds auth(EPosition) &Pool which satisfies the EPosition | ERebalance
/// requirement of Pool.rebalancePosition.
///
/// @param pid:   Position to rebalance
/// @param force: Whether to force rebalance regardless of health bounds
transaction(pid: UInt64, force: Bool) {
    let pool: auth(FlowALPModels.EPosition) &FlowALPv0.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        let cap = signer.storage.borrow<&Capability<auth(FlowALPModels.EPosition) &FlowALPv0.Pool>>(
            from: FlowALPv0.PoolCapStoragePath
        ) ?? panic("EPosition capability not found at PoolCapStoragePath")
        self.pool = cap.borrow() ?? panic("Could not borrow Pool with EPosition")
    }

    execute {
        // Pool.rebalancePosition — requires EPosition | ERebalance; EPosition alone is sufficient
        self.pool.rebalancePosition(pid: pid, force: force)
    }
}
