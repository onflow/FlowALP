// Returns the details of a specific position by its ID.
import "FlowALPv0"

access(all) fun main(positionID: UInt64): FlowALPv0.PositionDetails {
    let protocolAddress = Type<@FlowALPv0.Pool>().address!
    let account = getAccount(protocolAddress)
    let pool = account.capabilities.borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
        ?? panic("Could not find Pool at path \(FlowALPv0.PoolPublicPath)")

    return pool.getPositionDetails(pid: positionID)
}
