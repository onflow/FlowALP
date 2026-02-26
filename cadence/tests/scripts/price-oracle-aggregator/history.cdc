import "PriceOracleAggregatorv1"

access(all) fun main(storageID: UInt64): &[PriceOracleAggregatorv1.PriceHistoryEntry] {
    let priceOracle = PriceOracleAggregatorv1.createPriceOracleAggregator(storageID: storageID)
    return priceOracle.priceHistory()
}
