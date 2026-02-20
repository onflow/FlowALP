import "FlowALPv0"
import "FlowALPModels"

transaction(
    enabled: Bool
) {
    let pool: auth(FlowALPModels.EGovernance) &FlowALPv0.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALPModels.EGovernance) &FlowALPv0.Pool>(from: FlowALPv0.PoolStoragePath)
            ?? panic("Could not borrow Pool at \(FlowALPv0.PoolStoragePath)")
    }

    execute {
        self.pool.borrowConfig().setDebugLogging(enabled)
    }
}


