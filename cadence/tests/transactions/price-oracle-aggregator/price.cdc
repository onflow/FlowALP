import "FlowPriceOracleAggregatorv1"

transaction(
    storageID: UInt64,
    forToken: Type,
) {
    execute {
        let _ = FlowPriceOracleAggregatorv1.createPriceOracleAggregator(storageID: storageID).price(
            ofToken: forToken,
        )
    }
}