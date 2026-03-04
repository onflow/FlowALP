import "FlowALPv0"

/// Updates the interest curve for an existing supported token to a KinkInterestCurve.
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
            interestCurve: FlowALPv0.KinkInterestCurve(
                optimalUtilization: optimalUtilization,
                baseRate: baseRate,
                slope1: slope1,
                slope2: slope2
            )
        )
    }
}
