import "FlowCreditMarket"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Runs a single async update for the provided position ID.
transaction(pid: UInt64) {
    let pool: auth(FlowCreditMarket.EImplementation) &FlowCreditMarket.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowCreditMarket.EImplementation) &FlowCreditMarket.Pool>(
            from: FlowCreditMarket.PoolStoragePath
        ) ?? panic("Could not borrow Pool at \(FlowCreditMarket.PoolStoragePath)")
    }

    execute {
        self.pool.asyncUpdatePosition(pid: pid)
    }
}
