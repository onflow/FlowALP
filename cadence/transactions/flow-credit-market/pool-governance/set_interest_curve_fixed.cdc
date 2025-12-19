import "FlowCreditMarket"

/// Updates the interest curve for an existing supported token to a FixedRateInterestCurve.
/// This sets a constant yearly interest rate regardless of utilization.
///
transaction(
    tokenTypeIdentifier: String,
    yearlyRate: UFix128
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
        self.pool.setInterestCurve(
            tokenType: self.tokenType,
            interestCurve: FlowCreditMarket.FixedRateInterestCurve(yearlyRate: yearlyRate)
        )
    }
}
