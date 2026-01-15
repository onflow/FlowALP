import "FlowCreditMarket"

/// Returns the timestamp of the last stability collection for a given token type.
/// This can be used to calculate how much time has elapsed since last collection.
///
/// @param tokenTypeIdentifier: The Type identifier of the token vault (e.g., "A.0x07.MOET.Vault")
/// @return: The Unix timestamp of last collection, or nil if token type is not supported
access(all) fun main(tokenTypeIdentifier: String): UFix64? {
    let tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")

    let protocolAddress = Type<@FlowCreditMarket.Pool>().address!
    let pool = getAccount(protocolAddress).capabilities.borrow<&FlowCreditMarket.Pool>(FlowCreditMarket.PoolPublicPath)
        ?? panic("Could not find Pool at path \(FlowCreditMarket.PoolPublicPath)")
    
    return pool.getLastStabilityCollection(tokenType: tokenType)
}