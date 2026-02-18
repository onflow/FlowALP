import "FlowPriceOracleAggregatorv1"

access(all) fun main(uuid: UInt64): &[FlowPriceOracleAggregatorv1.PriceHistoryEntry] {
    let priceOracle = FlowPriceOracleAggregatorv1.createPriceOracleAggregator(id: uuid)
    return priceOracle.priceHistory()
}
