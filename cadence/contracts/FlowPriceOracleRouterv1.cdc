import "DeFiActions"

access(all) contract FlowPriceOracleRouterv1 {

    access(all) struct PriceOracleRouter: DeFiActions.PriceOracle {
        access(self) let oracles: {Type: {DeFiActions.PriceOracle}}
        access(self) let unitOfAccountType: Type
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        init(unitOfAccount: Type, oracles: {Type: {DeFiActions.PriceOracle}}) {
            self.unitOfAccountType = unitOfAccount
            self.uniqueID = DeFiActions.createUniqueIdentifier()
            for oracle in oracles.values {
                if oracle.unitOfAccount() != unitOfAccount {
                    panic("Oracle unit of account does not match router unit of account")
                }
            }
            self.oracles = oracles
        }

        access(all) fun price(ofToken: Type): UFix64? {
            return self.oracles[ofToken]?.price(ofToken: ofToken) ?? nil
        }

        access(all) view fun unitOfAccount(): Type {
            return self.unitOfAccountType
        }

        access(all) view fun id(): UInt64 {
            return self.uniqueID!.id
        }

        access(all) fun getID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }

        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
                innerComponents: []
            )
        }

        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) {
            self.uniqueID = id
        }

        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }
    }

    access(all) fun createPriceOracleRouter(
        unitOfAccount: Type,
        oracles: {Type: {DeFiActions.PriceOracle}},
    ): PriceOracleRouter {
        return PriceOracleRouter(unitOfAccount: unitOfAccount, oracles: oracles)
    }
}