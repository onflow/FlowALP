import "FlowOracleAggregatorv1"

access(all) fun main(uuid: UInt64, ofToken: Type): UFix64? {
    let priceOracle = FlowOracleAggregatorv1.createPriceOracleAggregator(id: uuid)
    return priceOracle.price(ofToken: ofToken)
}
