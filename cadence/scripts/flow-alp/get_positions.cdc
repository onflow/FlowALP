// Returns up to `count` position details starting from index `startIndex`
// in the pool's position IDs array.
import "FlowALPv0"

access(all) fun main(startIndex: UInt64, count: UInt64): [FlowALPv0.PositionDetails] {
    let protocolAddress = Type<@FlowALPv0.Pool>().address!
    let account = getAccount(protocolAddress)
    let pool = account.capabilities.borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
        ?? panic("Could not find Pool at path \(FlowALPv0.PoolPublicPath)")

    let total = pool.getPositionCount()

    if startIndex >= total {
        return []
    }

    var endIndex: UInt64 = 0
    if startIndex + count > total {
        endIndex = total
    } else {
        endIndex = startIndex + count
    }

    var positions: [FlowALPv0.PositionDetails] = []
    var i = startIndex

    while i < endIndex {
        positions.append(pool.getPositionDetailsAtIndex(index: i))
        i = i + 1
    }

    return positions
}
