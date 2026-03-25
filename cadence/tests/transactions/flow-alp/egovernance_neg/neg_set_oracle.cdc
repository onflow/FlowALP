import "DeFiActions"
import "FlowALPv0"
import "FlowALPModels"
import "MockOracle"

/// NEGATIVE TEST TRANSACTION — DO NOT USE IN PRODUCTION
///
/// Verifies that auth(ERebalance | EPosition | EImplementation | EParticipant | EPositionAdmin) &Pool
/// does NOT grant access to Pool.setPriceOracle.
/// This transaction fails at Cadence check time: setPriceOracle requires EGovernance.
transaction {
    let pool: auth(FlowALPModels.ERebalance | FlowALPModels.EPosition | FlowALPModels.EImplementation | FlowALPModels.EParticipant | FlowALPModels.EPositionAdmin) &FlowALPv0.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        let cap = signer.storage.borrow<&Capability<auth(FlowALPModels.ERebalance | FlowALPModels.EPosition | FlowALPModels.EImplementation | FlowALPModels.EParticipant | FlowALPModels.EPositionAdmin) &FlowALPv0.Pool>>(
            from: FlowALPv0.PoolCapStoragePath
        ) ?? panic("No pool cap found")
        self.pool = cap.borrow() ?? panic("Could not borrow Pool from cap")
    }

    execute {
        self.pool.setPriceOracle(MockOracle.PriceOracle())
        // TYPE ERROR: setPriceOracle requires EGovernance
    }
}
