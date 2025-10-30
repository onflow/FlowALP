import "FlowALP"

/// Returns whether there is a Pool stored in the provided account's address. This address would normally be the
/// FlowALP contract address
///
access(all)
fun main(address: Address): Bool {
    return getAccount(address).storage.type(at: FlowALP.PoolStoragePath) == Type<@FlowALP.Pool>()
}
