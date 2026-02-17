import "FungibleToken"

import "DeFiActions"

///
/// THIS CONTRACT IS A MOCK AND IS NOT INTENDED FOR USE IN PRODUCTION
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
access(all) contract MultiMockOracle {

    access(all) event OracleCreated(uuid: UInt64)

    access(all) var priceOracleStorages: @{UInt64: PriceOracleStorage}

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

    access(all) struct PriceOracle : DeFiActions.PriceOracle {
        access(contract) var priceOracleStorageID: UInt64
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
            return (&MultiMockOracle.priceOracleStorages[self.priceOracleStorageID])!
        }

        init(priceOracleStorageID: UInt64) {
            self.priceOracleStorageID = priceOracleStorageID
            self.uniqueID = DeFiActions.createUniqueIdentifier()
        }
    }

    access(all) fun createPriceOracle(unitOfAccountType: Type): PriceOracle {
        let oracleStorage <- create PriceOracleStorage(unitOfAccountType: unitOfAccountType)
        let id = oracleStorage.uuid
        self.priceOracleStorages[id] <-! oracleStorage
        emit OracleCreated(uuid: id)
        let oracle = PriceOracle(priceOracleStorageID: id)
        return oracle
    }

    access(all) view fun borrowPriceOracleStorage(priceOracleStorageID: UInt64): &PriceOracleStorage? {
        return &self.priceOracleStorages[priceOracleStorageID]
    }

    access(all) fun setPrice(priceOracleStorageID: UInt64, forToken: Type, price: UFix64?) {
        let oracleStorage = self.borrowPriceOracleStorage(priceOracleStorageID: priceOracleStorageID)!
        oracleStorage.setPrice(forToken: forToken, price: price)
    }

    init() {
        self.priceOracleStorages <- {}
    }
}
