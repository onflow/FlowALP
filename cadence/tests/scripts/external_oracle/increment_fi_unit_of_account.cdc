import "DeFiActions"
import "FlowToken"
import "USDCFlow"
import "IncrementFiSwapConnectors"

/// Builds a DeFiActions.PriceOracle using IncrementFiSwapConnectors.PriceOracle
/// and returns the unitOfAccount identifier
access(all) fun main(unitOfAccount: Type, baseToken: Type, path: [String]): String? {
    let oracle = IncrementFiSwapConnectors.PriceOracle(
        unitOfAccount: unitOfAccount,
        baseToken: baseToken,
        path: path,
        uniqueID: nil
    )
    return oracle.unitOfAccount().identifier
}
