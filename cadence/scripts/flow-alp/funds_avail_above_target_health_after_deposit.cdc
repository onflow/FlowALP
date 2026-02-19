import "FlowALPv0"

access(all)
fun main(
    pid: UInt64,
    withdrawType: String,
    targetHealth: UFix128,
    depositType: String,
    depositAmount: UFix64
): UFix64 {
    let _withdrawType = CompositeType(withdrawType) ?? panic("Invalid Vault identifier withdrawType \(withdrawType)")
    let _depositType = CompositeType(depositType) ?? panic("Invalid Vault identifier depositType \(depositType)")
    let address = Type<@FlowALPv0.Pool>().address!
    return getAccount(address).capabilities.borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
        ?.fundsAvailableAboveTargetHealthAfterDepositing(
            pid: pid,
            withdrawType: _withdrawType,
            targetHealth: targetHealth,
            depositType: _depositType,
            depositAmount: depositAmount
        ) ?? panic("Could not reference FlowALPv0 Pool at address \(address) at PublicPath \(FlowALPv0.PoolPublicPath)")
}
