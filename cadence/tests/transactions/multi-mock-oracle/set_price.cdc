import "MultiMockOracle"

transaction(
    oracleStorageID: UInt64,
    forToken: Type,
    price: UFix64?,
) {
    execute {
        MultiMockOracle.setPrice(
            priceOracleStorageID: oracleStorageID,
            forToken: forToken,
            price: price,
        )
    }
}