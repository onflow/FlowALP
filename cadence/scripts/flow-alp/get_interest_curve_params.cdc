import "FlowALPv0"

/// Returns interest curve parameters for the specified token type.
///
/// Always returns:
/// - curveType
/// - currentDebitRatePerSecond
/// - currentCreditRatePerSecond
///
/// For FixedCurve, also returns:
/// - yearlyRate
///
/// For KinkCurve, also returns:
/// - optimalUtilization
/// - baseRate
/// - slope1
/// - slope2
///
/// @param tokenTypeIdentifier: The Type identifier of the token vault (e.g., "A.0x07.MOET.Vault")
/// @return A map of curve parameters, or nil if the token type is not supported
access(all) fun main(tokenTypeIdentifier: String): {String: AnyStruct}? {
    let tokenType = CompositeType(tokenTypeIdentifier)
        ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")

    let protocolAddress = Type<@FlowALPv0.Pool>().address!
    let pool = getAccount(protocolAddress).capabilities.borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
        ?? panic("Could not find Pool at path \(FlowALPv0.PoolPublicPath)")

    return pool.getInterestCurveParams(tokenType: tokenType)
}
