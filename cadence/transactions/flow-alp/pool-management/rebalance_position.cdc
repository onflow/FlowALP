import "FlowALP"

/// Rebalances a FlowALP position by it's Position ID with the provided `force` value
///
/// @param pid: The position ID to rebalance
/// @param force: Whether the rebalance execution should be forced or not. If `false`, the rebalance executes only if
///     the position is beyond its min/max health. If `true`, the rebalance executes regardless of its relative health.
///
transaction(pid: UInt64, force: Bool) {
    let pool: auth(FlowALP.EPosition) &FlowALP.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALP.EPosition) &FlowALP.Pool>(from: FlowALP.PoolStoragePath)
            ?? panic("Could not borrow reference to Pool from \(FlowALP.PoolStoragePath) - ensure a Pool has been configured")
    }
    
    execute {
        self.pool.rebalancePosition(pid: pid, force: force)
    }
}
