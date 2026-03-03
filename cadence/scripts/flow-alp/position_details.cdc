import "FlowALPv0"
import "FlowALPModels"

/// Returns the position health for a given position id, reverting if the position does not exist
///
/// @param pid: The Position ID
///
access(all)
fun main(pid: UInt64): FlowALPModels.PositionDetails {
    let protocolAddress= Type<@FlowALPv0.Pool>().address!
    return getAccount(protocolAddress).capabilities.borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
        ?.getPositionDetails(pid: pid)
        ?? panic("Could not find a configured FlowALPv0 Pool in account \(protocolAddress) at path \(FlowALPv0.PoolPublicPath)")
}
