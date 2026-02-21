import "OracleStorage"
import "FlowPriceOracleRouterv1"

access(all) fun main(): [Type] {
    let oracle = OracleStorage.oracle!
    let router = oracle as! &FlowPriceOracleRouterv1.PriceOracleRouter
    return router.getSupportedTokens()
}
