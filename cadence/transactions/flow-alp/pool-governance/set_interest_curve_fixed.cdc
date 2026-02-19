import "FlowALPv0"
import "FlowALPInterestRates"

/// Updates the interest curve for an existing supported token to a FixedCurve.
/// This sets a constant yearly interest rate regardless of utilization.
///
transaction(
    tokenTypeIdentifier: String,
    yearlyRate: UFix128
) {
    let tokenType: Type
    let pool: auth(FlowALPv0.EGovernance) &FlowALPv0.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")
        self.pool = signer.storage.borrow<auth(FlowALPv0.EGovernance) &FlowALPv0.Pool>(from: FlowALPv0.PoolStoragePath)
            ?? panic("Could not borrow reference to Pool from \(FlowALPv0.PoolStoragePath) - ensure a Pool has been configured")
    }

    execute {
        self.pool.setInterestCurve(
            tokenType: self.tokenType,
            interestCurve: FlowALPInterestRates.FixedCurve(yearlyRate: yearlyRate)
        )
    }
}
