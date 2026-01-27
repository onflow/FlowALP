import "FlowCreditMarket"

/// Rebuilds queued deposit amounts for a given position ID.
transaction(pid: UInt64) {
    let pool: auth(FlowCreditMarket.EImplementation) &FlowCreditMarket.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowCreditMarket.EImplementation) &FlowCreditMarket.Pool>(
            from: FlowCreditMarket.PoolStoragePath
        ) ?? panic("Could not borrow Pool at \(FlowCreditMarket.PoolStoragePath)")
    }

    execute {
        self.pool.syncQueuedDepositAmounts(pid: pid)
    }
}
