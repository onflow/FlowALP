import "FlowALPv0"

/// Returns the queued deposit balances for a given position id.
///
/// @param pid: The Position ID
///
access(all)
fun main(pid: UInt64): {Type: UFix64} {
    let protocolAddress = Type<@FlowALPv0.Pool>().address!
    return getAccount(protocolAddress).capabilities.borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
        ?.getQueuedDeposits(pid: pid)
        ?? panic("Could not find a configured FlowALPv0 Pool in account \(protocolAddress) at path \(FlowALPv0.PoolPublicPath)")
}
