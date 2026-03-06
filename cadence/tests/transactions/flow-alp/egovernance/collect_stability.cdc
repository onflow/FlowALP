import "FlowALPv0"
import "FlowALPModels"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Verifies that auth(EGovernance) &Pool grants access to Pool.collectStability.
transaction(tokenTypeIdentifier: String) {
    let pool: auth(FlowALPModels.EGovernance) &FlowALPv0.Pool
    let tokenType: Type

    prepare(signer: auth(BorrowValue) &Account) {
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier: \(tokenTypeIdentifier)")
        let cap = signer.storage.borrow<&Capability<auth(FlowALPModels.EGovernance) &FlowALPv0.Pool>>(
            from: FlowALPv0.PoolCapStoragePath
        ) ?? panic("No EGovernance cap found")
        self.pool = cap.borrow() ?? panic("Could not borrow Pool from EGovernance cap")
    }

    execute {
        self.pool.collectStability(tokenType: self.tokenType)
    }
}
