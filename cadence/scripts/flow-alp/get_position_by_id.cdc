import "FlowALPv0"
import "FlowALPModels"

access(all) fun main(poolAddress: Address, positionID: UInt64): FlowALPModels.PositionDetails {
    let account = getAccount(poolAddress)

    let poolRef = account.capabilities
        .borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
        ?? panic("Could not borrow Pool reference from \(poolAddress)")

    return poolRef.getPositionDetails(pid: positionID)
}