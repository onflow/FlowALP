import "FlowCreditMarket"

/// Returns the current balance of the MOET insurance fund
///
/// @return The insurance fund balance in MOET tokens
access(all) fun main(): UFix64 {
    let protocolAddress = Type<@FlowCreditMarket.Pool>().address!
    let pool = getAccount(protocolAddress).capabilities.borrow<&FlowCreditMarket.Pool>(FlowCreditMarket.PoolPublicPath)
        ?? panic("Could not find Pool at path \(FlowCreditMarket.PoolPublicPath)")
    
    return pool.insuranceFundBalance()
}