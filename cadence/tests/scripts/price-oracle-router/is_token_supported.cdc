import "OracleStorage"
import "FlowPriceOracleRouterv1"

access(all) fun main(tokenType: Type): Bool {
    let oracle = OracleStorage.oracle!
    let router = oracle as! &FlowPriceOracleRouterv1.PriceOracleRouter
    return router.isTokenSupported(tokenType: tokenType)
}
