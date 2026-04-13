import "FlowALPv0"
import "FlowALPModels"

/// NEGATIVE TEST TRANSACTION — DO NOT USE IN PRODUCTION
///
/// Verifies that auth(ERebalance) &Pool does NOT grant access to Pool.setInsuranceRate.
/// This transaction fails at Cadence check time: setInsuranceRate requires EGovernance.
transaction(
    tokenTypeIdentifier: String,
    insuranceRate: UFix64
) {
    let pool: auth(FlowALPModels.ERebalance | FlowALPModels.EPosition | FlowALPModels.EImplementation | FlowALPModels.EParticipant | FlowALPModels.EPositionAdmin) &FlowALPv0.Pool
    let tokenType: Type

    prepare(signer: auth(BorrowValue) &Account) {
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")
        let cap = signer.storage.borrow<&Capability<auth(FlowALPModels.ERebalance | FlowALPModels.EPosition | FlowALPModels.EImplementation | FlowALPModels.EParticipant | FlowALPModels.EPositionAdmin) &FlowALPv0.Pool>>(
            from: FlowALPv0.PoolCapStoragePath
        ) ?? panic("No ERebalance cap found")
        self.pool = cap.borrow() ?? panic("Could not borrow Pool from ERebalance cap")
    }

    execute {
        self.pool.setInsuranceRate(tokenType: self.tokenType, insuranceRate: insuranceRate)
        // TYPE ERROR: setInsuranceRate requires EGovernance
    }
}
