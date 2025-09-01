import "TidalProtocol"

access(all)
fun main(): {String: AnyStruct} {
    let protocolAddress = Type<@TidalProtocol.Pool>().address!
    let pool = getAccount(protocolAddress).capabilities.borrow<&TidalProtocol.Pool>(TidalProtocol.PoolPublicPath)
        ?? panic("Could not find Pool at path \(TidalProtocol.PoolPublicPath)")
    return pool.getDexLiquidationConfig()
}


