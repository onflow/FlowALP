import "FlowALPv0"

/// Adds a token type as supported to the stored pool with a zero-rate interest curve (0% APY).
/// This uses FixedRateInterestCurve with yearlyRate: 0.0, suitable for testing or
/// scenarios where no interest should accrue.
///
transaction(
    tokenTypeIdentifier: String,
    collateralFactor: UFix64,
    borrowFactor: UFix64,
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
            interestCurve: FlowALPv0.FixedRateInterestCurve(yearlyRate: 0.0),
            depositRate: depositRate,
            depositCapacityCap: depositCapacityCap
        )
    }
}
