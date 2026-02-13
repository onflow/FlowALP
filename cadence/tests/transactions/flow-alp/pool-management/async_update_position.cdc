import "FlowALPv1"
import "FlowALPModels"

/// Async update a FlowALPv1 position by it's Position ID
///
/// @param pid: The position ID to update
///
transaction(pid: UInt64) {
    let pool: auth(FlowALPModels.EImplementation) &FlowALPv1.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALPModels.EImplementation) &FlowALPv1.Pool>(from: FlowALPv1.PoolStoragePath)
            ?? panic("Could not borrow reference to Pool from \(FlowALPv1.PoolStoragePath) - ensure a Pool has been configured")
    }
    
    execute {
        self.pool.asyncUpdatePosition(pid: pid)
    }
}
