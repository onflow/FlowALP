import "FlowALPv0"

/// Returns the current balance of the stability fund for a given token type
///
/// @param tokenTypeIdentifier: The Type identifier of the token vault (e.g., "A.0x07.MOET.Vault")
/// @return The current stability balance for the token type, or nil if the token is not supported
access(all) fun main(tokenTypeIdentifier: String): UFix64? {
    let tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")

    let protocolAddress = Type<@FlowALPv0.Pool>().address!
    let pool = getAccount(protocolAddress).capabilities.borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
        ?? panic("Could not find Pool at path \(FlowALPv0.PoolPublicPath)")
    
    return pool.getStabilityFundBalance(tokenType: tokenType)
}
