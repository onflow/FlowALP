// Returns the IDs of all currently open positions in the pool.
import "FlowALPv0"

access(all) fun main(): [UInt64] {
    let protocolAddress = Type<@FlowALPv0.Pool>().address!
    let account = getAccount(protocolAddress)
    let pool = account.capabilities.borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
        ?? panic("Could not find Pool at path \(FlowALPv0.PoolPublicPath)")

    return pool.getPositionIDs()
}
