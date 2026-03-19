import "FlowALPv0"

access(all)
fun main(pid: UInt64, vaultIdentifier: String, pullFromTopUpSource: Bool): UFix64 {
    let vaultType = CompositeType(vaultIdentifier) ?? panic("Invalid vaultIdentifier \(vaultIdentifier)")

    let protocolAddress= Type<@FlowALPv0.Pool>().address!

    let pool = getAccount(protocolAddress).capabilities.borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
        ?? panic("Could not find a configured FlowALPv0 Pool in account \(protocolAddress) at path \(FlowALPv0.PoolPublicPath)")

    return pool.availableBalance(pid: pid, type: vaultType, pullFromTopUpSource: pullFromTopUpSource)
}
