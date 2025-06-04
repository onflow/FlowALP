import TidalProtocol from "TidalProtocol"

access(all) fun main(poolAddress: Address, pid: UInt64): UFix64 {
    let poolCap = getAccount(poolAddress)
        .capabilities.get<&TidalProtocol.Pool>(/public/tidalPool)
        .borrow()
        ?? panic("Could not borrow pool capability")
    
    return poolCap.positionHealth(pid: pid)
} 