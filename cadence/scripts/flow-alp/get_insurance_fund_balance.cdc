import "FlowALPv1"

/// Returns the current balance of the MOET insurance fund
///
/// @return The insurance fund balance in MOET tokens
access(all) fun main(): UFix64 {
    let protocolAddress = Type<@FlowALPv1.Pool>().address!
    let pool = getAccount(protocolAddress).capabilities.borrow<&FlowALPv1.Pool>(FlowALPv1.PoolPublicPath)
        ?? panic("Could not find Pool at path \(FlowALPv1.PoolPublicPath)")
    
    return pool.insuranceFundBalance()
}
