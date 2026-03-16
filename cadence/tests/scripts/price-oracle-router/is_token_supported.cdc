import "OracleStorage"
import "PriceOracleRouterv1"

access(all) fun main(tokenType: Type): Bool {
    let oracle = OracleStorage.oracle!
    let router = oracle as! &PriceOracleRouterv1.PriceOracleRouter
    return router.isTokenSupported(tokenType: tokenType)
}
