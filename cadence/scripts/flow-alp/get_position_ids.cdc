import "FlowALPv0"

access(all) fun main(poolAddress: Address, poolUUID: UInt64): [UInt64] {
    let account = getAccount(poolAddress)

    let poolRef = account.capabilities
        .borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
        ?? panic("Could not borrow Pool reference from \(poolAddress)")

    return poolRef.getPositionIDs()
}
