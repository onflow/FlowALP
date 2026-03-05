import "FlowALPv0"
import "FlowALPModels"

/// Sets the stability fee rate for a specific token type.
///
/// Only governance-authorized accounts can execute this transaction.
///
/// @param tokenTypeIdentifier: The fully qualified type identifier of the token (e.g., "A.0x1.FlowToken.Vault")
/// @param stabilityFeeRate: The fee rate as a fraction in [0, 1]
///
///
/// Emits: StabilityFeeRateUpdated
transaction(
    tokenTypeIdentifier: String,
    stabilityFeeRate: UFix64
) {
    let pool: auth(FlowALPModels.EGovernance) &FlowALPv0.Pool
    let tokenType: Type

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALPModels.EGovernance) &FlowALPv0.Pool>(from: FlowALPv0.PoolStoragePath)
            ?? panic("Could not borrow Pool at \(FlowALPv0.PoolStoragePath)")
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")
    }

    execute {
        self.pool.setStabilityFeeRate(tokenType: self.tokenType, stabilityFeeRate: stabilityFeeRate)
    }
}


