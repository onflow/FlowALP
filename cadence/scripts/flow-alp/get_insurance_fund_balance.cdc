import "FlowALPv0"

/// Returns the current balance of the MOET insurance fund
///
/// @return The insurance fund balance in MOET tokens
access(all) fun main(): UFix64 {
    let protocolAddress = Type<@FlowALPv0.Pool>().address!
    let pool = getAccount(protocolAddress).capabilities.borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
        ?? panic("Could not find Pool at path \(FlowALPv0.PoolPublicPath)")
    
    return pool.insuranceFundBalance()
}
