import "FlowALPv0"
import "FlowALPModels"

/// TEST SETUP — grants an ERebalance Pool capability to a rebalancer account.
/// Simulates how FlowALPRebalancerv1 obtains narrowly-scoped rebalancing rights.
/// Stored at FlowALPv0.PoolCapStoragePath.
transaction {
    prepare(
        admin: auth(IssueStorageCapabilityController) &Account,
        user: auth(Storage) &Account
    ) {
        let cap = admin.capabilities.storage.issue<auth(FlowALPModels.ERebalance) &FlowALPv0.Pool>(
            FlowALPv0.PoolStoragePath
        )
        // Overwrite any existing cap at this path
        if user.storage.type(at: FlowALPv0.PoolCapStoragePath) != nil {
            user.storage.load<Capability<auth(FlowALPModels.ERebalance) &FlowALPv0.Pool>>(
                from: FlowALPv0.PoolCapStoragePath
            )
        }
        user.storage.save(cap, to: FlowALPv0.PoolCapStoragePath)
    }
}
