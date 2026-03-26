import "FlowALPv0"
import "FlowALPModels"

/// Regenerates deposit capacities for all supported token types via EImplementation.
/// Recalculates deposit capacity based on the configured deposit rate. Safe to call at any time.
transaction {
    let pool: auth(FlowALPModels.EImplementation) &FlowALPv0.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALPModels.EImplementation) &FlowALPv0.Pool>(from: FlowALPv0.PoolStoragePath)
            ?? panic("Could not borrow Pool with EImplementation entitlement")
    }

    execute {
        self.pool.regenerateAllDepositCapacities()
    }
}
