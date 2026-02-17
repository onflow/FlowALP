import "FlowALPv1"

/// Returns whether there is a Pool stored in the provided account's address. This address would normally be the
/// FlowALPv1 contract address
///
access(all)
fun main(address: Address): Bool {
    return getAccount(address).storage.type(at: FlowALPv1.PoolStoragePath) == Type<@FlowALPv1.Pool>()
}
