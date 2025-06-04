import TidalProtocol from "TidalProtocol"

// Script to check if an account has a pool capability published
access(all) fun main(address: Address): Bool {
    let account = getAccount(address)
    
    // Check if the account has a pool capability published
    let poolCap = account.capabilities.get<&TidalProtocol.Pool>(
        /public/tidalProtocolPool
    )
    
    return poolCap.check()
} 