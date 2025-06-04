import TidalProtocol from "TidalProtocol"

access(all) fun main(accountAddress: Address, positionID: UInt64): TidalProtocol.PositionDetails? {
    // Get the pool capability from the account
    let capability = getAccount(accountAddress).capabilities
        .get<&TidalProtocol.Pool>(/public/testPool)
    
    if let pool = capability.borrow() {
        // Get position details
        return pool.getPositionDetails(pid: positionID)
    }
    
    return nil
} 