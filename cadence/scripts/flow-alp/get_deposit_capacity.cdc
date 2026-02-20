import "FlowALPv0"

/// Returns the Pool's deposit capacity and deposit capacity cap for a given Vault type
///
/// @param vaultIdentifier: The Type identifier (e.g. vault.getType().identifier) of the related token vault
///
access(all)
fun main(vaultIdentifier: String): {String: UFix64} {
    let vaultType = CompositeType(vaultIdentifier) ?? panic("Invalid vaultIdentifier \(vaultIdentifier)")

    let protocolAddress = Type<@FlowALPv0.Pool>().address!

    let pool = getAccount(protocolAddress).capabilities.borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
        ?? panic("Could not find a configured FlowALPv0 Pool in account \(protocolAddress) at path \(FlowALPv0.PoolPublicPath)")

    return pool.getDepositCapacityInfo(type: vaultType)
}

