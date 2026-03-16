import "MultiMockOracle"

transaction(
    storageID: UInt64,
    forToken: Type,
    price: UFix64?,
) {
    execute {
        MultiMockOracle.setPrice(
            storageID: storageID,
            forToken: forToken,
            price: price,
        )
    }
}