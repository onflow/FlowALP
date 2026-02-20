import "FlowALPv0"

/// Returns whether there is a Pool stored in the provided account's address. This address would normally be the
/// FlowALPv0 contract address
///
access(all)
fun main(address: Address): Bool {
    return getAccount(address).storage.type(at: FlowALPv0.PoolStoragePath) == Type<@FlowALPv0.Pool>()
}
