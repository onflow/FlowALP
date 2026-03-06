import "FlowALPv0"
import "FlowALPModels"
import "FlowALPInterestRates"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Verifies that auth(EGovernance) &Pool grants access to Pool.setInterestCurve.
/// Sets a FixedCurve with the given yearly rate.
transaction(
    tokenTypeIdentifier: String,
    yearlyRate: UFix128
) {
    let tokenType: Type
    let pool: auth(FlowALPModels.EGovernance) &FlowALPv0.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")
        let cap = signer.storage.borrow<&Capability<auth(FlowALPModels.EGovernance) &FlowALPv0.Pool>>(
            from: FlowALPv0.PoolCapStoragePath
        ) ?? panic("No EGovernance cap found")
        self.pool = cap.borrow() ?? panic("Could not borrow Pool from EGovernance cap")
    }

    execute {
        self.pool.setInterestCurve(
            tokenType: self.tokenType,
            interestCurve: FlowALPInterestRates.FixedCurve(yearlyRate: yearlyRate)
        )
    }
}
