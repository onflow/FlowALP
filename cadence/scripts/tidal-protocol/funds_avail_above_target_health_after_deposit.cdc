import "TidalProtocol"

access(all)
fun main(
    pid: UInt64,
    withdrawType: String,
    targetHealth: UInt128,
    depositType: String,
    depositAmount: UFix64
): UFix64 {
    let _withdrawType = CompositeType(withdrawType) ?? panic("Invalid Vault identifier withdrawType \(withdrawType)")
    let _depositType = CompositeType(depositType) ?? panic("Invalid Vault identifier depositType \(depositType)")
    let address = Type<@TidalProtocol.Pool>().address!
    return getAccount(address).capabilities.borrow<&TidalProtocol.Pool>(TidalProtocol.PoolPublicPath)
        ?.fundsAvailableAboveTargetHealthAfterDepositing(
            pid: pid,
            withdrawType: _withdrawType,
            targetHealth: targetHealth,
            depositType: _depositType,
            depositAmount: depositAmount
        ) ?? panic("Could not reference TidalProtocol Pool at address \(address) at PublicPath \(TidalProtocol.PoolPublicPath)")
}
