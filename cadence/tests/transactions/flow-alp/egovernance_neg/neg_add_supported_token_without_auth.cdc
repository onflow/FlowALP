import "FlowALPv0"
import "FlowALPModels"
import "FlowALPInterestRates"

/// NEGATIVE TEST TRANSACTION — DO NOT USE IN PRODUCTION
///
/// Verifies that an unauthorized &Pool ref (no entitlements at all) cannot call
/// Pool.addSupportedToken. The Pool is obtained via the public capability published
/// at FlowALPv0.PoolPublicPath — no stored cap is required, so any account can run
/// this transaction. It fails at Cadence check time because addSupportedToken
/// requires EGovernance, which an unauthorized &Pool does not carry.
transaction(
    tokenTypeIdentifier: String,
    collateralFactor: UFix64,
    borrowFactor: UFix64,
    depositRate: UFix64,
    depositCapacityCap: UFix64,
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
        self.pool.addSupportedToken(
            tokenType: self.tokenType,
            collateralFactor: collateralFactor,
            borrowFactor: borrowFactor,
            interestCurve: FlowALPInterestRates.FixedCurve(yearlyRate: 0.0),
            depositRate: depositRate,
            depositCapacityCap: depositCapacityCap
        )  // TYPE ERROR: addSupportedToken requires EGovernance
    }
}
