import "FlowCreditMarket"

/// Returns the next position ID for a given pool
///
/// @param poolUUID: The UUID of the pool
///
access(all)
fun main(): UInt64 {
    let pool = getAuthAccount<auth(BorrowValue) &Account>(Type<@FlowCreditMarket.Pool>().address!).storage.borrow<&FlowCreditMarket.Pool>(
            from:FlowCreditMarket.PoolStoragePath
        ) ?? panic("Could not borrow reference to Pool from \(FlowCreditMarket.PoolStoragePath) - ensure a Pool has been configured")
    return pool.nextPositionID
}
