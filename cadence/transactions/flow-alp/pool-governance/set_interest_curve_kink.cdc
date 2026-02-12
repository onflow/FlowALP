import "FlowALPv1"
import "FlowALPInterestRates"

/// Updates the interest curve for an existing supported token to a KinkCurve.
/// This allows changing from the default zero-rate curve to a utilization-based variable rate.
///
transaction(
    tokenTypeIdentifier: String,
    optimalUtilization: UFix128,
    baseRate: UFix128,
    slope1: UFix128,
    slope2: UFix128
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
            interestCurve: FlowALPInterestRates.KinkCurve(
                optimalUtilization: optimalUtilization,
                baseRate: baseRate,
                slope1: slope1,
                slope2: slope2
            )
        )
    }
}
