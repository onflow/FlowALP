import "FlowCreditMarket"

access(all)
fun main(): {String: AnyStruct} {
    let protocolAddress = Type<@FlowCreditMarket.Pool>().address!
    let pool = getAccount(protocolAddress).capabilities.borrow<&FlowCreditMarket.Pool>(FlowCreditMarket.PoolPublicPath)
        ?? panic("Could not find Pool at path \(FlowCreditMarket.PoolPublicPath)")
    return pool.getDexLiquidationConfig()
}
