import "DeFiActions"
import "FlowALPv0"
import "FlowALPModels"
import "MockDexSwapper"

/// NEGATIVE TEST TRANSACTION — DO NOT USE IN PRODUCTION
///
/// Verifies that an unauthorized &Pool ref (no entitlements at all) cannot call
/// Pool.borrowConfig / setDex. The Pool is obtained via the public capability published
/// at FlowALPv0.PoolPublicPath — no stored cap is required, so any account can run
/// this transaction. It fails at Cadence check time because borrowConfig
/// requires EGovernance, which an unauthorized &Pool does not carry.
transaction(poolAddress: Address) {
    let pool: &FlowALPv0.Pool

    prepare(signer: &Account) {
        self.pool = getAccount(poolAddress).capabilities
            .borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
            ?? panic("Pool not available at public path")
    }

    execute {
        self.pool.borrowConfig().setDex(MockDexSwapper.SwapperProvider())
        // TYPE ERROR: borrowConfig requires EGovernance
    }
}
