import "FlowPriceOracleAggregatorv1"

access(all) fun main(uuid: UInt64, ofToken: Type): UFix64? {
    let priceOracle = FlowPriceOracleAggregatorv1.createPriceOracleAggregator(id: uuid)
    return priceOracle.price(ofToken: ofToken)
}
