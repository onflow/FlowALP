import "FungibleToken"

import "DeFiActions"

/// Test-only mock: implements `DeFiActions.PriceOracle` with settable prices
/// per token. Use to feed the aggregator or router in tests.
access(all) contract MultiMockOracle {

    access(all) event OracleCreated(storageID: UInt64)

    access(all) var priceOracleStorages: @{UInt64: PriceOracleStorage}

    /// Holds unit-of-account type and a mutable map of token type -> price.
    access(all) resource PriceOracleStorage {
        access(contract) var unitOfAccountType: Type
        access(contract) var prices: {Type: UFix64?}

        access(all) fun setPrice(forToken: Type, price: UFix64?) {
            self.prices[forToken] = price
        }

        init(unitOfAccountType: Type) {
            self.unitOfAccountType = unitOfAccountType
            self.prices = {}
        }
    }

    /// Mock oracle view over storage; implements DeFiActions.PriceOracle.
    /// Unit-of-account always returns 1.0; other tokens use set prices.
    access(all) struct PriceOracle : DeFiActions.PriceOracle {
        access(all) var storageID: UInt64
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        access(all) view fun unitOfAccount(): Type {
            return self.borrowPriceOracleStorage().unitOfAccountType
        }

        access(all) fun price(ofToken: Type): UFix64? {
            if ofToken == self.borrowPriceOracleStorage().unitOfAccountType {
                return 1.0
            }
            return self.borrowPriceOracleStorage().prices[ofToken] ?? nil
        }

        access(all) fun setPrice(forToken: Type, price: UFix64?) {
            self.borrowPriceOracleStorage().setPrice(forToken: forToken, price: price)
        }

        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
                innerComponents: []
            )
        }

        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }

        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) {
            self.uniqueID = id
        }

        access(all) view fun borrowPriceOracleStorage(): &PriceOracleStorage {
            return (&MultiMockOracle.priceOracleStorages[self.storageID])!
        }

        init(storageID: UInt64) {
            self.storageID = storageID
            self.uniqueID = DeFiActions.createUniqueIdentifier()
        }
    }

    /// Creates a new mock oracle storage and returns a PriceOracle view.
    access(all) fun createPriceOracle(unitOfAccountType: Type): PriceOracle {
        let oracleStorage <- create PriceOracleStorage(unitOfAccountType: unitOfAccountType)
        let id = oracleStorage.uuid
        self.priceOracleStorages[id] <-! oracleStorage
        emit OracleCreated(storageID: id)
        let oracle = PriceOracle(storageID: id)
        return oracle
    }

    access(all) view fun borrowPriceOracleStorage(storageID: UInt64): &PriceOracleStorage? {
        return &self.priceOracleStorages[storageID]
    }

    /// Sets the price for a token on the given storage (for tests).
    access(all) fun setPrice(storageID: UInt64, forToken: Type, price: UFix64?) {
        let oracleStorage = self.borrowPriceOracleStorage(storageID: storageID)!
        oracleStorage.setPrice(forToken: forToken, price: price)
    }

    init() {
        self.priceOracleStorages <- {}
    }
}
