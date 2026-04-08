import "DeFiActions"
import "IncrementFiSwapConnectors"

/// Builds a DeFiActions.PriceOracle using IncrementFiSwapConnectors.PriceOracle
/// and returns price(ofToken: FLOW).
access(all) fun main(unitOfAccount: Type, baseToken: Type, path: [String]): UFix64? {
    let oracle = IncrementFiSwapConnectors.PriceOracle(
        unitOfAccount: unitOfAccount,
        baseToken: baseToken,
        path: path,
        uniqueID: nil
    )
    let price = oracle.price(ofToken: baseToken)
    return price
}
