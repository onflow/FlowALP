import "FlowALPv0"
import "FlowALPModels"

/// TEST SETUP — grants an EPosition-ONLY Pool capability to a user account.
/// This is a narrowly-scoped capability — no EParticipant, so the holder cannot
/// createPosition. EPosition alone allows pool-level position operations on any
/// position by ID (withdraw, depositAndPush, lockPosition, rebalancePosition, etc.).
/// Stored at FlowALPv0.PoolCapStoragePath.
transaction {
    prepare(
        admin: auth(IssueStorageCapabilityController) &Account,
        user: auth(Storage) &Account
    ) {
        let cap = admin.capabilities.storage.issue<auth(FlowALPModels.EPosition) &FlowALPv0.Pool>(
            FlowALPv0.PoolStoragePath
        )
        // Overwrite any existing cap at this path
        if user.storage.type(at: FlowALPv0.PoolCapStoragePath) != nil {
            user.storage.load<Capability<auth(FlowALPModels.EPosition) &FlowALPv0.Pool>>(
                from: FlowALPv0.PoolCapStoragePath
            )
        }
        user.storage.save(cap, to: FlowALPv0.PoolCapStoragePath)
    }
}
