import "OracleStorage"
import "PriceOracleRouterv1"

access(all) fun main(): [Type] {
    let oracle = OracleStorage.oracle!
    let router = oracle as! &PriceOracleRouterv1.PriceOracleRouter
    return router.getSupportedTokens()
}
