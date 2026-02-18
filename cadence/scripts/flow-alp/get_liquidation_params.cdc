import "FlowALPv1"
import "FlowALPModels"

access(all)
fun main(): FlowALPModels.LiquidationParamsView {
    let protocolAddress = Type<@FlowALPv1.Pool>().address!
    let pool = getAccount(protocolAddress).capabilities.borrow<&FlowALPv1.Pool>(FlowALPv1.PoolPublicPath)
        ?? panic("Could not find Pool at path \(FlowALPv1.PoolPublicPath)")
    return pool.getLiquidationParams()
}
