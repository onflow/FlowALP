import "FlowPriceOracleAggregatorv1"

access(all) fun main(storageID: UInt64): &[FlowPriceOracleAggregatorv1.PriceHistoryEntry] {
    let priceOracle = FlowPriceOracleAggregatorv1.createPriceOracleAggregator(storageID: storageID)
    return priceOracle.priceHistory()
}
