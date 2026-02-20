import "FlowALPv0"

access(all)
fun main(): {String: AnyStruct} {
    let protocolAddress = Type<@FlowALPv0.Pool>().address!
    let pool = getAccount(protocolAddress).capabilities.borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
        ?? panic("Could not find Pool at path \(FlowALPv0.PoolPublicPath)")
    return pool.getDexLiquidationConfig()
}
