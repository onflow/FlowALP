import "FlowALP"

access(all)
fun main(pid: UInt64, debtVaultIdentifier: String, seizeVaultIdentifier: String): FlowALP.LiquidationQuote {
    let debtType = CompositeType(debtVaultIdentifier) ?? panic("Invalid debtVaultIdentifier \(debtVaultIdentifier)")
    let seizeType = CompositeType(seizeVaultIdentifier) ?? panic("Invalid seizeVaultIdentifier \(seizeVaultIdentifier)")

    let protocolAddress = Type<@FlowALP.Pool>().address!
    let pool = getAccount(protocolAddress).capabilities.borrow<&FlowALP.Pool>(FlowALP.PoolPublicPath)
        ?? panic("Could not find Pool at path \(FlowALP.PoolPublicPath)")

    return pool.quoteLiquidation(pid: pid, debtType: debtType, seizeType: seizeType)
}
