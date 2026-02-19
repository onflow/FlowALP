import "FlowALPv1"

/// Returns whether a position is eligible for liquidation
///
/// A position is liquidatable when its health factor is below 1.0,
/// indicating it has crossed the global liquidation threshold.
///
/// @param pid: The unique identifier of the position.
/// @return `true` if the position can be liquidated, otherwise `false`.
access(all) fun main(pid: UInt64): Bool {
    let protocolAddress = Type<@FlowALPv1.Pool>().address!
    let pool = getAccount(protocolAddress).capabilities.borrow<&FlowALPv1.Pool>(FlowALPv1.PoolPublicPath)
        ?? panic("Could not find Pool at path \(FlowALPv1.PoolPublicPath)")
    
    return pool.isLiquidatable(pid: pid)
}
