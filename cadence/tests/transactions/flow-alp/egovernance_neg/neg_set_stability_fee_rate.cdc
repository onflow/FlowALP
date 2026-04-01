import "FlowALPv0"
import "FlowALPModels"

/// NEGATIVE TEST TRANSACTION — DO NOT USE IN PRODUCTION
///
/// Verifies that auth(ERebalance | EPosition | EImplementation | EParticipant | EPositionAdmin) &Pool
/// does NOT grant access to Pool.setStabilityFeeRate.
/// This transaction fails at Cadence check time: setStabilityFeeRate requires EGovernance.
transaction(
    tokenTypeIdentifier: String,
    stabilityFeeRate: UFix64
) {
    let pool: auth(FlowALPModels.ERebalance | FlowALPModels.EPosition | FlowALPModels.EImplementation | FlowALPModels.EParticipant | FlowALPModels.EPositionAdmin) &FlowALPv0.Pool
    let tokenType: Type

    prepare(signer: auth(BorrowValue) &Account) {
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")
        let cap = signer.storage.borrow<&Capability<auth(FlowALPModels.ERebalance | FlowALPModels.EPosition | FlowALPModels.EImplementation | FlowALPModels.EParticipant | FlowALPModels.EPositionAdmin) &FlowALPv0.Pool>>(
            from: FlowALPv0.PoolCapStoragePath
        ) ?? panic("No pool cap found")
        self.pool = cap.borrow() ?? panic("Could not borrow Pool from cap")
    }

    execute {
        self.pool.setStabilityFeeRate(tokenType: self.tokenType, stabilityFeeRate: stabilityFeeRate)
        // TYPE ERROR: setStabilityFeeRate requires EGovernance
    }
}
