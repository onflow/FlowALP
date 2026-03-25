import "FlowALPv0"
import "FlowALPModels"
import "FlowALPInterestRates"

/// NEGATIVE TEST TRANSACTION — DO NOT USE IN PRODUCTION
///
/// Verifies that auth(ERebalance | EPosition | EImplementation | EParticipant | EPositionAdmin) &Pool
/// does NOT grant access to Pool.setInterestCurve.
/// This transaction fails at Cadence check time: setInterestCurve requires EGovernance.
transaction(
    tokenTypeIdentifier: String,
    yearlyRate: UFix128
) {
    let tokenType: Type
    let pool: auth(FlowALPModels.ERebalance | FlowALPModels.EPosition | FlowALPModels.EImplementation | FlowALPModels.EParticipant | FlowALPModels.EPositionAdmin) &FlowALPv0.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")
        let cap = signer.storage.borrow<&Capability<auth(FlowALPModels.ERebalance | FlowALPModels.EPosition | FlowALPModels.EImplementation | FlowALPModels.EParticipant | FlowALPModels.EPositionAdmin) &FlowALPv0.Pool>>(
            from: FlowALPv0.PoolCapStoragePath
        ) ?? panic("No pool cap found")
        self.pool = cap.borrow() ?? panic("Could not borrow Pool from cap")
    }

    execute {
        self.pool.setInterestCurve(
            tokenType: self.tokenType,
            interestCurve: FlowALPInterestRates.FixedCurve(yearlyRate: yearlyRate)
        )  // TYPE ERROR: setInterestCurve requires EGovernance
    }
}
