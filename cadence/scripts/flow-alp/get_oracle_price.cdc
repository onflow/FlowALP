import "MockOracle"

access(all) fun main(tokenIdentifier: String): UFix64? {
    let tokenType = CompositeType(tokenIdentifier)
        ?? panic("Invalid token identifier: ".concat(tokenIdentifier))

    let oracle = MockOracle.PriceOracle()
    return oracle.price(ofToken: tokenType)
}
