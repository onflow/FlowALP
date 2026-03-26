// Returns the details of open positions for the given IDs.
// Positions with no non-zero balances (closed) are excluded from the result.
import "FlowALPv0"
import "FlowALPModels"

access(all) fun main(positionIDs: [UInt64]): [FlowALPModels.PositionDetails] {
    let protocolAddress = Type<@FlowALPv0.Pool>().address!
    let account = getAccount(protocolAddress)
    let pool = account.capabilities.borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
        ?? panic("Could not find Pool at path \(FlowALPv0.PoolPublicPath)")

    let details: [FlowALPModels.PositionDetails] = []
    for id in positionIDs {
        let d = pool.getPositionDetails(pid: id)
        var hasBalance = false
        for balance in d.balances {
            if balance.balance > 0.0 {
                hasBalance = true
                break
            }
        }
        
        if hasBalance {
            details.append(d)
        }
    }

    return details
}
