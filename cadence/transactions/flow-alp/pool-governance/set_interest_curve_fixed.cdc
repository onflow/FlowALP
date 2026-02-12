import "FlowALPv1"
import "FlowALPRateCurves"

/// Updates the interest curve for an existing supported token to a FixedRateInterestCurve.
/// This sets a constant yearly interest rate regardless of utilization.
///
transaction(
    tokenTypeIdentifier: String,
    yearlyRate: UFix128
) {
    let tokenType: Type
    let pool: auth(FlowALPv1.EGovernance) &FlowALPv1.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")
        self.pool = signer.storage.borrow<auth(FlowALPv1.EGovernance) &FlowALPv1.Pool>(from: FlowALPv1.PoolStoragePath)
            ?? panic("Could not borrow reference to Pool from \(FlowALPv1.PoolStoragePath) - ensure a Pool has been configured")
    }

    execute {
        self.pool.setInterestCurve(
            tokenType: self.tokenType,
            interestCurve: FlowALPRateCurves.FixedRateInterestCurve(yearlyRate: yearlyRate)
        )
    }
}
