// Returns the details of a position by its ID, or nil if the position does not exist.
import "FlowALPv0"

access(all) fun main(positionID: UInt64): FlowALPv0.PositionDetails? {
    let protocolAddress = Type<@FlowALPv0.Pool>().address!
    let account = getAccount(protocolAddress)
    let pool = account.capabilities.borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
        ?? panic("Could not find Pool at path \(FlowALPv0.PoolPublicPath)")

    return pool.tryGetPositionDetails(pid: positionID)
}
