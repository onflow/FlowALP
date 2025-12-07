import "FlowCreditMarket"

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
    let address = Type<@FlowCreditMarket.Pool>().address!
    return getAccount(address).capabilities.borrow<&FlowCreditMarket.Pool>(FlowCreditMarket.PoolPublicPath)
        ?.fundsAvailableAboveTargetHealthAfterDepositing(
            pid: pid,
            withdrawType: _withdrawType,
            targetHealth: targetHealth,
            depositType: _depositType,
            depositAmount: depositAmount
        ) ?? panic("Could not reference FlowCreditMarket Pool at address \(address) at PublicPath \(FlowCreditMarket.PoolPublicPath)")
}
