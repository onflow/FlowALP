import "FlowALPv0"
import "FlowALPModels"

/// Sets the stability fee rate for the given token type.
/// Requires an EGovernance capability at PoolCapStoragePath.
transaction(
    tokenTypeIdentifier: String,
    stabilityFeeRate: UFix64
) {
    let pool: auth(FlowALPModels.EGovernance) &FlowALPv0.Pool
    let tokenType: Type

    prepare(signer: auth(BorrowValue) &Account) {
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")
        let cap = signer.storage.borrow<&Capability<auth(FlowALPModels.EGovernance) &FlowALPv0.Pool>>(
            from: FlowALPv0.PoolCapStoragePath
        ) ?? panic("No EGovernance cap found")
        self.pool = cap.borrow() ?? panic("Could not borrow Pool from EGovernance cap")
    }

    execute {
        self.pool.setStabilityFeeRate(tokenType: self.tokenType, stabilityFeeRate: stabilityFeeRate)
    }
}
