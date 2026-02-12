import "FlowALPv1"
import "FlowALPRateCurves"

/// Adds a token type as supported to the stored pool with a fixed-rate interest curve.
/// This uses FixedRateInterestCurve for a constant yearly interest rate regardless of utilization.
///
transaction(
    tokenTypeIdentifier: String,
    collateralFactor: UFix64,
    borrowFactor: UFix64,
    yearlyRate: UFix128,
    depositRate: UFix64,
    depositCapacityCap: UFix64
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
        self.pool.addSupportedToken(
            tokenType: self.tokenType,
            collateralFactor: collateralFactor,
            borrowFactor: borrowFactor,
            interestCurve: FlowALPRateCurves.FixedRateInterestCurve(yearlyRate: yearlyRate),
            depositRate: depositRate,
            depositCapacityCap: depositCapacityCap
        )
    }
}
