import "TidalProtocol"

access(all)
fun main(
    pid: UInt64,
    depositType: String,
    targetHealth: UInt256,
    withdrawType: String,
    withdrawAmount: UFix64
): UFix64 {
    let _depositType = CompositeType(depositType) ?? panic("Invalid Vault identifier depositType \(depositType)")
    let _withdrawType = CompositeType(withdrawType) ?? panic("Invalid Vault identifier withdrawType \(withdrawType)")
    let address = Type<@TidalProtocol.Pool>().address!
    return getAccount(address).capabilities.borrow<&TidalProtocol.Pool>(TidalProtocol.PoolPublicPath)
        ?.fundsRequiredForTargetHealthAfterWithdrawing(
            pid: pid,
            depositType: _depositType,
            targetHealth: targetHealth,
            withdrawType: _withdrawType,
            withdrawAmount: withdrawAmount
        ) ?? panic("Could not reference TidalProtocol Pool at address \(address) at PublicPath \(TidalProtocol.PoolPublicPath)")
}
