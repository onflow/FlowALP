import "FlowOracleAggregatorv1"

access(all) fun main(uuid: UInt64): &[FlowOracleAggregatorv1.PriceHistoryEntry] {
    let priceOracle = FlowOracleAggregatorv1.createPriceOracleAggregator(id: uuid)
    return priceOracle.priceHistory()
}
