import "FlowCreditMarket"

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
    let pool: auth(FlowCreditMarket.EGovernance) &FlowCreditMarket.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")
        self.pool = signer.storage.borrow<auth(FlowCreditMarket.EGovernance) &FlowCreditMarket.Pool>(from: FlowCreditMarket.PoolStoragePath)
            ?? panic("Could not borrow reference to Pool from \(FlowCreditMarket.PoolStoragePath) - ensure a Pool has been configured")
    }

    execute {
        self.pool.addSupportedToken(
            tokenType: self.tokenType,
            collateralFactor: collateralFactor,
            borrowFactor: borrowFactor,
            interestCurve: FlowCreditMarket.FixedRateInterestCurve(yearlyRate: yearlyRate),
            depositRate: depositRate,
            depositCapacityCap: depositCapacityCap
        )
    }
}
