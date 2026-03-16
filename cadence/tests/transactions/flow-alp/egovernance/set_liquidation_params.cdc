import "FlowALPv0"
import "FlowALPModels"

/// Sets the liquidation target health factor via Pool.borrowConfig.
/// Requires an EGovernance capability at PoolCapStoragePath.
///
/// @param targetHF: The target health factor for liquidations (must be > 1.0)
transaction(targetHF: UFix128) {
    let pool: auth(FlowALPModels.EGovernance) &FlowALPv0.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        let cap = signer.storage.borrow<&Capability<auth(FlowALPModels.EGovernance) &FlowALPv0.Pool>>(
            from: FlowALPv0.PoolCapStoragePath
        ) ?? panic("No EGovernance cap found")
        self.pool = cap.borrow() ?? panic("Could not borrow Pool from EGovernance cap")
    }

    execute {
        self.pool.borrowConfig().setLiquidationTargetHF(targetHF)
    }
}
