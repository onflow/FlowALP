import "FlowALPv0"
import "FlowALPModels"

/// TEST SETUP — grants an EParticipant-ONLY Pool capability to a user account.
/// This is the FIXED beta capability — no EPosition over-grant.
/// Stored at FlowALPv0.PoolCapStoragePath.
transaction {
    prepare(
        admin: auth(IssueStorageCapabilityController) &Account,
        user: auth(Storage) &Account
    ) {
        let cap = admin.capabilities.storage.issue<auth(FlowALPModels.EParticipant) &FlowALPv0.Pool>(
            FlowALPv0.PoolStoragePath
        )
        // Overwrite any existing cap at this path
        if user.storage.type(at: FlowALPv0.PoolCapStoragePath) != nil {
            user.storage.load<Capability<auth(FlowALPModels.EParticipant) &FlowALPv0.Pool>>(
                from: FlowALPv0.PoolCapStoragePath
            )
        }
        user.storage.save(cap, to: FlowALPv0.PoolCapStoragePath)
    }
}
