import "FlowCreditMarket"

/// Pauses or unpauses liquidations on the pool.
/// When unpausing, starts a warmup period before liquidations become active.
///
/// @param flag: true to pause, false to unpause
transaction(flag: Bool) {
    let pool: auth(FlowCreditMarket.EGovernance) &FlowCreditMarket.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowCreditMarket.EGovernance) &FlowCreditMarket.Pool>(from: FlowCreditMarket.PoolStoragePath)
            ?? panic("Could not borrow Pool at \(FlowCreditMarket.PoolStoragePath)")
    }

    execute {
        self.pool.pauseLiquidations(flag: flag)
    }
}
