import "FlowALPv0"

/// Returns the total number of currently active positions in the FlowALPv0 Pool.
///
access(all)
fun main(): Int {
    let protocolAddress = Type<@FlowALPv0.Pool>().address!
    return getAccount(protocolAddress).capabilities.borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
        ?.getPositionCount()
        ?? panic("Could not find a configured FlowALPv0 Pool in account \(protocolAddress) at path \(FlowALPv0.PoolPublicPath)")
}
