import "FlowALPv1"

/// Returns the Pool's reserve balance for all Vault types in a given Pool
///
/// @param poolAddress: The address of the Pool
///
access(all)
fun main(poolAddress: Address): {String: UFix64} {
    let account = getAccount(poolAddress)
    
    let poolRef = account.capabilities
        .borrow<&FlowALPv1.Pool>(FlowALPv1.PoolPublicPath)
        ?? panic("Could not borrow Pool reference from \(poolAddress)")
    
    let supportedTokens = poolRef.getSupportedTokens()
    let reserves: {String: UFix64} = {}
    
    for tokenType in supportedTokens {
        let balance = poolRef.reserveBalance(type: tokenType)
        reserves[tokenType.identifier] = balance
    }
    
    return reserves
}