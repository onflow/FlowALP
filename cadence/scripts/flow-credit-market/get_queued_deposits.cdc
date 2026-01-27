import "FlowCreditMarket"

/// Returns the queued deposit balances for a given position id
///
/// @param pid: The Position ID
/// @return A dictionary mapping token types to their queued deposit amounts
///
access(all)
fun main(pid: UInt64): {Type: UFix64} {
    let protocolAddress = Type<@FlowCreditMarket.Pool>().address!
    return getAccount(protocolAddress).capabilities.borrow<&FlowCreditMarket.Pool>(FlowCreditMarket.PoolPublicPath)
        ?.getQueuedDeposits(pid: pid)
        ?? panic("Could not find a configured FlowCreditMarket Pool in account \(protocolAddress) at path \(FlowCreditMarket.PoolPublicPath)")
}
