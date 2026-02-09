import "FlowCreditMarket"

/// Async update a FlowCreditMarket position by it's Position ID
///
/// @param pid: The position ID to update
///
transaction(pid: UInt64) {
    let pool: auth(FlowCreditMarket.EImplementation) &FlowCreditMarket.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowCreditMarket.EImplementation) &FlowCreditMarket.Pool>(from: FlowCreditMarket.PoolStoragePath)
            ?? panic("Could not borrow reference to Pool from \(FlowCreditMarket.PoolStoragePath) - ensure a Pool has been configured")
    }
    
    execute {
        self.pool.asyncUpdatePosition(pid: pid)
    }
}
