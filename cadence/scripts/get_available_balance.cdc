import TidalProtocol from "../contracts/TidalProtocol.cdc"

access(all) fun main(poolAddress: Address, positionId: UInt64, tokenType: String): UFix64 {
    // Get the pool reference
    let pool = getAccount(poolAddress).capabilities.borrow<&TidalProtocol.Pool>(
        /public/tidalPool
    ) ?? panic("Could not borrow pool reference")

    // Parse the token type
    let vaultType = CompositeType(tokenType) 
        ?? panic("Invalid token type identifier")

    // Get the position
    let position = pool.borrowPosition(pid: positionId)
        ?? panic("Position not found")

    // Get available balance (includes source integration)
    return position.getAvailableBalance(tokenType: vaultType)
} 