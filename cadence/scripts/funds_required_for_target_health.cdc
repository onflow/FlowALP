import TidalProtocol from "TidalProtocol"

access(all) fun main(poolAddress: Address, pid: UInt64, tokenType: Type, targetHealth: UFix64): UFix64 {
    let poolCap = getAccount(poolAddress)
        .capabilities.get<&TidalProtocol.Pool>(/public/tidalPool)
        .borrow()
        ?? panic("Could not borrow pool capability")
    
    return poolCap.fundsRequiredForTargetHealth(
        pid: pid,
        type: tokenType,
        targetHealth: targetHealth
    )
} 