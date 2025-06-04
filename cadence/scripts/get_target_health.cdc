import TidalProtocol from "../contracts/TidalProtocol.cdc"

access(all) fun main(poolAddress: Address, positionId: UInt64): UFix64 {
    // Get the pool reference
    let pool = getAccount(poolAddress).capabilities.borrow<&TidalProtocol.Pool>(
        /public/tidalPool
    ) ?? panic("Could not borrow pool reference")

    // Get the position
    let position = pool.borrowPosition(pid: positionId)
        ?? panic("Position not found")

    // Note: getTargetHealth() always returns 1.5 in the Position struct interface
    // The actual target health is stored in InternalPosition and not accessible
    return position.getTargetHealth()
} 