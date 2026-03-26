// Returns the IDs of all currently open positions in the pool.
// A position is considered open if it has at least one non-zero balance.
import "FlowALPv0"

access(all) fun main(): [UInt64] {
    let protocolAddress = Type<@FlowALPv0.Pool>().address!
    let account = getAccount(protocolAddress)
    let pool = account.capabilities.borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
        ?? panic("Could not find Pool at path \(FlowALPv0.PoolPublicPath)")

    let allIDs = pool.getPositionIDs()
    let openIDs: [UInt64] = []
    for id in allIDs {
        let details = pool.getPositionDetails(pid: id)
        var hasBalance = false
        for balance in details.balances {
            if balance.balance > 0.0 {
                hasBalance = true
                break
            }
        }

        if hasBalance {
            openIDs.append(id)
        }
    }
    
    return openIDs
}
