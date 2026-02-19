<<<<<<< HEAD
import "FlowALPv1"
import "FlowALPInterestRates"
=======
import "FlowALPv0"
>>>>>>> main

/// Adds a token type as supported to the stored pool with a kink interest curve.
/// This uses KinkCurve for utilization-based variable interest rates,
/// modeled after Aave v3's DefaultReserveInterestRateStrategyV2.
///
transaction(
    tokenTypeIdentifier: String,
    collateralFactor: UFix64,
    borrowFactor: UFix64,
    optimalUtilization: UFix128,
    baseRate: UFix128,
    slope1: UFix128,
    slope2: UFix128,
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
            interestCurve: FlowALPInterestRates.KinkCurve(
=======
            interestCurve: FlowALPv0.KinkInterestCurve(
>>>>>>> main
                optimalUtilization: optimalUtilization,
                baseRate: baseRate,
                slope1: slope1,
                slope2: slope2
            ),
            depositRate: depositRate,
            depositCapacityCap: depositCapacityCap
        )
    }
}
