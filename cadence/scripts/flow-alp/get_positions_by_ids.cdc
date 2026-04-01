// Returns the details of multiple positions by their IDs.
// Positions that no longer exist (e.g., closed between fetching IDs and executing this script)
// are silently skipped.
import "FlowALPv0"

access(all) fun main(positionIDs: [UInt64]): [FlowALPv0.PositionDetails?] {
    let protocolAddress = Type<@FlowALPv0.Pool>().address!
    let account = getAccount(protocolAddress)
    let pool = account.capabilities.borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
        ?? panic("Could not find Pool at path \(FlowALPv0.PoolPublicPath)")

    let details: [FlowALPv0.PositionDetails?] = []
    for id in positionIDs {
        if let detail = pool.tryGetPositionDetails(pid: id) {
            details.append(detail)
        } else {
            details.append(nil)
        }
    }
    return details
}
