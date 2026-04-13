import "FlowALPv0"
import "FlowALPModels"

/// TEST TRANSACTION — DO NOT USE IN PRODUCTION
///
/// Verifies that auth(EImplementation) &Pool grants access to Pool.asyncUpdate.
/// EImplementation is never issued as an external capability — only the account
/// that owns the Pool in storage can access it. The queue may be empty; asyncUpdate
/// is a no-op in that case.
transaction {
    let pool: auth(FlowALPModels.EImplementation) &FlowALPv0.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALPModels.EImplementation) &FlowALPv0.Pool>(
            from: FlowALPv0.PoolStoragePath
        ) ?? panic("Could not borrow Pool with EImplementation entitlement")
    }

    execute {
        self.pool.asyncUpdate()
    }
}
