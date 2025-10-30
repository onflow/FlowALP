import "FlowALP"

access(all)
fun main(): {String: AnyStruct} {
    let protocolAddress = Type<@FlowALP.Pool>().address!
    let pool = getAccount(protocolAddress).capabilities.borrow<&FlowALP.Pool>(FlowALP.PoolPublicPath)
        ?? panic("Could not find Pool at path \(FlowALP.PoolPublicPath)")
    return pool.getDexLiquidationConfig()
}
