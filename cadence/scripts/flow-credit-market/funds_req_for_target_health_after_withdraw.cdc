import "FlowCreditMarket"

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
    let address = Type<@FlowCreditMarket.Pool>().address!
    return getAccount(address).capabilities.borrow<&FlowCreditMarket.Pool>(FlowCreditMarket.PoolPublicPath)
        ?.fundsRequiredForTargetHealthAfterWithdrawing(
            pid: pid,
            depositType: _depositType,
            targetHealth: targetHealth,
            withdrawType: _withdrawType,
            withdrawAmount: withdrawAmount
        ) ?? panic("Could not reference FlowCreditMarket Pool at address \(address) at PublicPath \(FlowCreditMarket.PoolPublicPath)")
}
