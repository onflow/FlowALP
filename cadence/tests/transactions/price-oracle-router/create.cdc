import "PriceOracleRouterv1"
import "OracleStorage"
import "DeFiActions"
import "MultiMockOracle"

transaction(
    unitOfAccount: Type,
    createRouterInfo: [{String: AnyStruct}],
) {
    execute {
        let oracles: {Type: {DeFiActions.PriceOracle}} = {}
        for info in createRouterInfo {
            // have to do this because transactions can't define structs?
            let unitOfAccount = info["unitOfAccount"] as! Type
            let oracleOfToken = info["oracleOfToken"] as! Type
            let price = info["price"] as! UFix64?
            let oracle = MultiMockOracle.createPriceOracle(unitOfAccountType: unitOfAccount)
            oracle.setPrice(forToken: oracleOfToken, price: price)
            oracles[oracleOfToken] = oracle
        }
        let router = PriceOracleRouterv1.createPriceOracleRouter(
            unitOfAccount: unitOfAccount,
            oracles: oracles,
        )
        OracleStorage.saveOracle(oracle: router)
    }
}