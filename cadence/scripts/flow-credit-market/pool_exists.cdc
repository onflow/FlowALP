import "FlowCreditMarket"

/// Returns whether there is a Pool stored in the provided account's address. This address would normally be the
/// FlowCreditMarket contract address
///
access(all)
fun main(address: Address): Bool {
    return getAccount(address).storage.type(at: FlowCreditMarket.PoolStoragePath) == Type<@FlowCreditMarket.Pool>()
}
