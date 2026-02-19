<<<<<<< HEAD
import "FlowALPv1"
import "FlowALPModels"
=======
import "FlowALPv0"
>>>>>>> main

/// Returns the position health for a given position id, reverting if the position does not exist
///
/// @param pid: The Position ID
///
access(all)
<<<<<<< HEAD
fun main(pid: UInt64): FlowALPModels.PositionDetails {
    let protocolAddress= Type<@FlowALPv1.Pool>().address!
    return getAccount(protocolAddress).capabilities.borrow<&FlowALPv1.Pool>(FlowALPv1.PoolPublicPath)
=======
fun main(pid: UInt64): FlowALPv0.PositionDetails {
    let protocolAddress= Type<@FlowALPv0.Pool>().address!
    return getAccount(protocolAddress).capabilities.borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
>>>>>>> main
        ?.getPositionDetails(pid: pid)
        ?? panic("Could not find a configured FlowALPv0 Pool in account \(protocolAddress) at path \(FlowALPv0.PoolPublicPath)")
}
