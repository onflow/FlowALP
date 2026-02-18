import "FlowPriceOracleAggregatorv1"

access(all) fun main(storageID: UInt64, ofToken: Type): UFix64? {
    let priceOracle = FlowPriceOracleAggregatorv1.createPriceOracleAggregator(storageID: storageID)
    return priceOracle.price(ofToken: ofToken)
}
