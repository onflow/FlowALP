import "TidalProtocol"

access(all)
fun main(pid: UInt64, debtVaultIdentifier: String, seizeVaultIdentifier: String): TidalProtocol.LiquidationQuote {
    let debtType = CompositeType(debtVaultIdentifier) ?? panic("Invalid debtVaultIdentifier \(debtVaultIdentifier)")
    let seizeType = CompositeType(seizeVaultIdentifier) ?? panic("Invalid seizeVaultIdentifier \(seizeVaultIdentifier)")

    let protocolAddress = Type<@TidalProtocol.Pool>().address!
    let pool = getAccount(protocolAddress).capabilities.borrow<&TidalProtocol.Pool>(TidalProtocol.PoolPublicPath)
        ?? panic("Could not find Pool at path \(TidalProtocol.PoolPublicPath)")

    return pool.quoteLiquidation(pid: pid, debtType: debtType, seizeType: seizeType)
}
