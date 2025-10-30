import "FlowALP"

access(all)
fun main(
    pid: UInt64,
    depositType: String,
    targetHealth: UFix128,
    withdrawType: String,
    withdrawAmount: UFix64
): UFix64 {
    let _depositType = CompositeType(depositType) ?? panic("Invalid Vault identifier depositType \(depositType)")
    let _withdrawType = CompositeType(withdrawType) ?? panic("Invalid Vault identifier withdrawType \(withdrawType)")
    let address = Type<@FlowALP.Pool>().address!
    return getAccount(address).capabilities.borrow<&FlowALP.Pool>(FlowALP.PoolPublicPath)
        ?.fundsRequiredForTargetHealthAfterWithdrawing(
            pid: pid,
            depositType: _depositType,
            targetHealth: targetHealth,
            withdrawType: _withdrawType,
            withdrawAmount: withdrawAmount
        ) ?? panic("Could not reference FlowALP Pool at address \(address) at PublicPath \(FlowALP.PoolPublicPath)")
}
