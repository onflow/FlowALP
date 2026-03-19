import "FlowALPv0"

/// Returns the timestamp of the last insurance collection for a given token type.
/// This can be used to calculate how much time has elapsed since last collection.
///
/// @param tokenTypeIdentifier: The Type identifier of the token vault (e.g., "A.0x07.MOET.Vault")
/// @return: The Unix timestamp of last collection, or nil if token type is not supported
access(all)
fun main(tokenTypeIdentifier: String): UFix64? {
    let tokenType = CompositeType(tokenTypeIdentifier)
        ?? panic("Invalid tokenTypeIdentifier: \(tokenTypeIdentifier)")

    let protocolAddress = Type<@FlowALPv0.Pool>().address!

    let pool = getAccount(protocolAddress).capabilities.borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
        ?? panic("Could not find Pool at path \(FlowALPv0.PoolPublicPath)")

    return pool.getLastInsuranceCollectionTime(tokenType: tokenType)
}
