import "FlowALPv0"
import "FlowALPModels"

/// Drains the async update queue, processing all queued positions.
transaction {
    let pool: auth(FlowALPModels.EImplementation) &FlowALPv0.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALPModels.EImplementation) &FlowALPv0.Pool>(from: FlowALPv0.PoolStoragePath)
            ?? panic("Could not borrow reference to Pool from \(FlowALPv0.PoolStoragePath) - ensure a Pool has been configured")
    }

    execute {
        self.pool.asyncUpdate()
    }
}
