import "PriceOracleAggregatorv1"

transaction(
    storageID: UInt64,
    forToken: Type,
) {
    execute {
        let _ = PriceOracleAggregatorv1.createPriceOracleAggregator(storageID: storageID).price(
            ofToken: forToken,
        )
    }
}