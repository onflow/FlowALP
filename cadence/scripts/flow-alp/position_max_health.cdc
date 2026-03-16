import "FlowALPv0"

/// Returns the maximum health for the given position.
///
/// @param positionOwner: The account address that holds the PositionManager
/// @param pid:           The position ID
access(all)
fun main(positionOwner: Address, pid: UInt64): UFix64 {
    let manager = getAccount(positionOwner).capabilities
        .borrow<&FlowALPv0.PositionManager>(FlowALPv0.PositionPublicPath)
        ?? panic("Could not borrow PositionManager from \(positionOwner) at \(FlowALPv0.PositionPublicPath)")
    return manager.borrowPosition(pid: pid).getMaxHealth()
}
