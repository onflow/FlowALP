import "DeFiActions"

access(all) contract FlowPriceOracleRouterv1 {

    access(all) entitlement Governance

    access(all) struct PriceOracleRouter: DeFiActions.PriceOracle {
        access(self) let oracles: {Type: {DeFiActions.PriceOracle}}
        access(self) let unitOfAccountType: Type
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        init(unitOfAccount: Type) {
            self.unitOfAccountType = unitOfAccount
            self.uniqueID = DeFiActions.createUniqueIdentifier()
            self.oracles = {}
        }

        access(all) fun price(ofToken: Type): UFix64? {
            return nil
        }

        access(all) fun addOracle(oracle: {DeFiActions.PriceOracle}, ofToken: Type) {
            pre {
                oracle.unitOfAccount() == self.unitOfAccountType:
                "Oracle unit of account does not match router unit of account"
                self.oracles[ofToken] == nil:
                "Oracle already added"
            }
            self.oracles[ofToken] = oracle
        }

        access(all) fun replaceOracle(oracle: {DeFiActions.PriceOracle}, ofToken: Type) {
            pre {
                oracle.unitOfAccount() == self.unitOfAccountType:
                "Oracle unit of account does not match router unit of account"
                self.oracles[ofToken] != nil:
                "Oracle not added"
            }
            self.oracles[ofToken] = oracle
        }

        access(all) fun removeOracle(ofToken: Type) {
            self.oracles.remove(key: ofToken)
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

    access(all) fun createPriceOracleRouter(unitOfAccount: Type): PriceOracleRouter {
        return PriceOracleRouter(unitOfAccount: unitOfAccount)
    }
}