<<<<<<< HEAD
import "FlowALPv1"
import "FlowALPInterestRates"
=======
import "FlowALPv0"
>>>>>>> main

/// Adds a token type as supported to the stored pool with a fixed-rate interest curve.
/// This uses FixedCurve for a constant yearly interest rate regardless of utilization.
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
    let pool: auth(FlowALPv0.EGovernance) &FlowALPv0.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")
        self.pool = signer.storage.borrow<auth(FlowALPv0.EGovernance) &FlowALPv0.Pool>(from: FlowALPv0.PoolStoragePath)
            ?? panic("Could not borrow reference to Pool from \(FlowALPv0.PoolStoragePath) - ensure a Pool has been configured")
    }

    execute {
        self.pool.addSupportedToken(
            tokenType: self.tokenType,
            collateralFactor: collateralFactor,
            borrowFactor: borrowFactor,
<<<<<<< HEAD
            interestCurve: FlowALPInterestRates.FixedCurve(yearlyRate: yearlyRate),
=======
            interestCurve: FlowALPv0.FixedRateInterestCurve(yearlyRate: yearlyRate),
>>>>>>> main
            depositRate: depositRate,
            depositCapacityCap: depositCapacityCap
        )
    }
}
