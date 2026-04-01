import "FlowALPv0"
import "FlowALPModels"

/// NEGATIVE TEST TRANSACTION — DO NOT USE IN PRODUCTION
///
/// Verifies that an unauthorized &Pool ref (no entitlements at all) cannot call
/// Pool.collectStability. The Pool is obtained via the public capability published
/// at FlowALPv0.PoolPublicPath — no stored cap is required, so any account can run
/// this transaction. It fails at Cadence check time because collectStability
/// requires EGovernance, which an unauthorized &Pool does not carry.
transaction(tokenTypeIdentifier: String, poolAddress: Address) {
    let pool: &FlowALPv0.Pool
    let tokenType: Type

    prepare(signer: &Account) {
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier: \(tokenTypeIdentifier)")
        self.pool = getAccount(poolAddress).capabilities
            .borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
            ?? panic("Pool not available at public path")
    }

    execute {
        self.pool.collectStability(tokenType: self.tokenType)
        // TYPE ERROR: collectStability requires EGovernance
    }
}
