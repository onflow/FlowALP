import "FlowALPv0"
import "FlowALPModels"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Verifies that Capability<auth(ERebalance) &Pool> (rebalancer capability) grants:
///   Pool.rebalancePosition
///
/// This simulates how FlowALPRebalancerv1 uses a narrow ERebalance capability
/// without being granted the broader EPosition entitlement.
///
/// @param pid:   Position to rebalance
/// @param force: Whether to force rebalance regardless of health bounds
transaction(pid: UInt64, force: Bool) {
    let pool: auth(FlowALPModels.ERebalance) &FlowALPv0.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        let cap = signer.storage.borrow<&Capability<auth(FlowALPModels.ERebalance) &FlowALPv0.Pool>>(
            from: FlowALPv0.PoolCapStoragePath
        ) ?? panic("ERebalance capability not found")
        self.pool = cap.borrow() ?? panic("Could not borrow Pool with ERebalance")
    }

    execute {
        // Pool.rebalancePosition — requires EPosition | ERebalance; ERebalance alone is sufficient
        self.pool.rebalancePosition(pid: pid, force: force)
    }
}
