import "FlowPriceOracleAggregatorv1"

transaction(
    oracleStorageID: UInt64,
    forToken: Type,
) {
    execute {
        FlowPriceOracleAggregatorv1.createPriceOracleAggregator(id: oracleStorageID).price(
            ofToken: forToken,
        )
    }
}