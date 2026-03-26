import "FlowALPv0"
import "FlowALPModels"
import "FlowALPInterestRates"

/// NEGATIVE TEST TRANSACTION — DO NOT USE IN PRODUCTION
///
/// Verifies that an unauthorized &Pool ref (no entitlements at all) cannot call
/// Pool.setInterestCurve. The Pool is obtained via the public capability published
/// at FlowALPv0.PoolPublicPath — no stored cap is required, so any account can run
/// this transaction. It fails at Cadence check time because setInterestCurve
/// requires EGovernance, which an unauthorized &Pool does not carry.
transaction(
    tokenTypeIdentifier: String,
    yearlyRate: UFix128,
    poolAddress: Address
) {
    let tokenType: Type
    let pool: &FlowALPv0.Pool

    prepare(signer: &Account) {
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")
        self.pool = getAccount(poolAddress).capabilities
            .borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
            ?? panic("Pool not available at public path")
    }

    execute {
        self.pool.setInterestCurve(
            tokenType: self.tokenType,
            interestCurve: FlowALPInterestRates.FixedCurve(yearlyRate: yearlyRate)
        )  // TYPE ERROR: setInterestCurve requires EGovernance
    }
}
