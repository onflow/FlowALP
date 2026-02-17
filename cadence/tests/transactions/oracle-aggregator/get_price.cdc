import "FlowOracleAggregatorv1"

transaction(
    oracleStorageID: UInt64,
    forToken: Type,
) {
    execute {
        FlowOracleAggregatorv1.createPriceOracleAggregator(id: oracleStorageID).price(
            ofToken: forToken,
        )
    }
}