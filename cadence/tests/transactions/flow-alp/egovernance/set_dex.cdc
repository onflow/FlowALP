import "DeFiActions"
import "FlowALPv0"
import "FlowALPModels"
import "MockDexSwapper"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Verifies that auth(EGovernance) &Pool grants access to Pool.borrowConfig,
/// enabling the governance holder to set the DEX via the config.
/// Uses MockDexSwapper.SwapperProvider as the DEX implementation.
transaction {
    let pool: auth(FlowALPModels.EGovernance) &FlowALPv0.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        let cap = signer.storage.borrow<&Capability<auth(FlowALPModels.EGovernance) &FlowALPv0.Pool>>(
            from: FlowALPv0.PoolCapStoragePath
        ) ?? panic("No EGovernance cap found")
        self.pool = cap.borrow() ?? panic("Could not borrow Pool from EGovernance cap")
    }

    execute {
        self.pool.borrowConfig().setDex(MockDexSwapper.SwapperProvider())
    }
}
