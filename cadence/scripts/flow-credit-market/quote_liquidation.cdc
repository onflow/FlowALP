import "FlowCreditMarket"

access(all)
fun main(pid: UInt64, debtVaultIdentifier: String, seizeVaultIdentifier: String): FlowCreditMarket.LiquidationQuote {
    let debtType = CompositeType(debtVaultIdentifier) ?? panic("Invalid debtVaultIdentifier \(debtVaultIdentifier)")
    let seizeType = CompositeType(seizeVaultIdentifier) ?? panic("Invalid seizeVaultIdentifier \(seizeVaultIdentifier)")

    let protocolAddress = Type<@FlowCreditMarket.Pool>().address!
    let pool = getAccount(protocolAddress).capabilities.borrow<&FlowCreditMarket.Pool>(FlowCreditMarket.PoolPublicPath)
        ?? panic("Could not find Pool at path \(FlowCreditMarket.PoolPublicPath)")

    return pool.quoteLiquidation(pid: pid, debtType: debtType, seizeType: seizeType)
}
