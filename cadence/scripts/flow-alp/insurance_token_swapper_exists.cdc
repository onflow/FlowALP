import "FlowALPv1"

/// Returns whether an insurance swapper is configured for a given token type.
/// When true, insurance collection is enabled for this token.
///
/// @param tokenTypeIdentifier: The Type identifier of the token vault (e.g., "A.0x07.MOET.Vault")
/// @return: true if swapper is configured, false otherwise
access(all)
fun main(tokenTypeIdentifier: String): Bool {
    let tokenType = CompositeType(tokenTypeIdentifier)
        ?? panic("Invalid tokenTypeIdentifier: \(tokenTypeIdentifier)")

    let protocolAddress = Type<@FlowALPv1.Pool>().address!

    let pool = getAccount(protocolAddress).capabilities.borrow<&FlowALPv1.Pool>(FlowALPv1.PoolPublicPath)
        ?? panic("Could not find Pool at path \(FlowALPv1.PoolPublicPath)")

    return pool.isInsuranceSwapperConfigured(tokenType: tokenType)
}
