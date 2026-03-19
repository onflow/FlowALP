import "FlowALPv0"

/// Returns the insurance rate for the specified token type
///
/// @param tokenTypeIdentifier: The Type identifier of the token vault (e.g., "A.0x07.MOET.Vault")
/// @return The insurance rate for the token type, or nil if the token type is not supported
access(all) fun main(tokenTypeIdentifier: String): UFix64? {
    let tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")

    let protocolAddress = Type<@FlowALPv0.Pool>().address!
    let pool = getAccount(protocolAddress).capabilities.borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
        ?? panic("Could not find Pool at path \(FlowALPv0.PoolPublicPath)")
    
    return pool.getInsuranceRate(tokenType: tokenType)
}
