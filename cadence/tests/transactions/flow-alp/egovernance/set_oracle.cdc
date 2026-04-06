import "DeFiActions"
import "FlowALPv0"
import "FlowALPModels"
import "MockOracle"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Verifies that auth(EGovernance) &Pool grants access to Pool.setPriceOracle.
/// Uses MockOracle.PriceOracle as the oracle implementation.
/// The MockOracle's unitOfAccount must match the pool's default token (MOET).
transaction {
    let pool: auth(FlowALPModels.EGovernance) &FlowALPv0.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        let cap = signer.storage.borrow<&Capability<auth(FlowALPModels.EGovernance) &FlowALPv0.Pool>>(
            from: FlowALPv0.PoolCapStoragePath
        ) ?? panic("No EGovernance cap found")
        self.pool = cap.borrow() ?? panic("Could not borrow Pool from EGovernance cap")
    }

    execute {
        // MockOracle.PriceOracle uses MOET as unitOfAccount, matching the pool's default token
        self.pool.setPriceOracle(MockOracle.PriceOracle())
    }
}
