import "FlowALPv0"
import "FlowALPModels"

/// NEGATIVE TEST TRANSACTION — DO NOT USE IN PRODUCTION
///
/// Verifies that an unauthorized &Pool ref (no entitlements at all) cannot call
/// Pool.pausePool / unpausePool. The Pool is obtained via the public capability published
/// at FlowALPv0.PoolPublicPath — no stored cap is required, so any account can run
/// this transaction. It fails at Cadence check time because pausePool and unpausePool
/// require EGovernance, which an unauthorized &Pool does not carry.
transaction(pause: Bool, poolAddress: Address) {
    let pool: &FlowALPv0.Pool

    prepare(signer: &Account) {
        self.pool = getAccount(poolAddress).capabilities
            .borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
            ?? panic("Pool not available at public path")
    }

    execute {
        if pause {
            self.pool.pausePool()      // TYPE ERROR: pausePool requires EGovernance
        } else {
            self.pool.unpausePool()    // TYPE ERROR: unpausePool requires EGovernance
        }
    }
}
