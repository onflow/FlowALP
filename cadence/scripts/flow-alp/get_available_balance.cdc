import "FlowALPv1"

access(all)
fun main(pid: UInt64, vaultIdentifier: String, pullFromTopUpSource: Bool): UFix64 {
    let vaultType = CompositeType(vaultIdentifier) ?? panic("Invalid vaultIdentifier \(vaultIdentifier)")

    let protocolAddress= Type<@FlowALPv1.Pool>().address!

    let pool = getAccount(protocolAddress).capabilities.borrow<&FlowALPv1.Pool>(FlowALPv1.PoolPublicPath)
        ?? panic("Could not find a configured FlowALPv1 Pool in account \(protocolAddress) at path \(FlowALPv1.PoolPublicPath)")

    return pool.availableBalance(pid: pid, type: vaultType, pullFromTopUpSource: pullFromTopUpSource)
}
