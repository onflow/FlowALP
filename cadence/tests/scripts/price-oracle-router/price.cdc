import "OracleStorage"

access(all) fun main(ofToken: Type): UFix64? {
    let oracle = OracleStorage.oracle!
    return oracle.price(ofToken: ofToken)
}
