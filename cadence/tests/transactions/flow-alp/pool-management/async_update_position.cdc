import "FlowALPv0"
import "FlowALPModels"

/// Async update a FlowALPv0 position by it's Position ID
///
/// @param pid: The position ID to update
///
transaction(pid: UInt64) {
    let pool: auth(FlowALPModels.EImplementation) &FlowALPv0.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALPModels.EImplementation) &FlowALPv0.Pool>(from: FlowALPv0.PoolStoragePath)
            ?? panic("Could not borrow reference to Pool from \(FlowALPv0.PoolStoragePath) - ensure a Pool has been configured")
    }

    execute {
        self.pool.asyncUpdatePosition(pid: pid)
    }
}
