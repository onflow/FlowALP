import "FlowPriceOracleAggregatorv1"

transaction(
    storageID: UInt64,
    forToken: Type,
    price: UFix64?,
) {
    execute {
        let realPrice = FlowPriceOracleAggregatorv1.createPriceOracleAggregator(storageID: storageID).price(
            ofToken: forToken,
        )
        if price != realPrice {
            log(price)
            log(realPrice)
            panic("invalid price")
        }
    }
}