import "DeFiActions"

/// Borrows the Band oracle as DeFiActions.PriceOracle at
/// /public/bandOraclePriceOracle (created by create_band_empty_fee.cdc)
/// and returns the unitOfAccount type identifier.
access(all) fun main(ownerAddress: Address): String? {
    let oracleRef = getAccount(ownerAddress).capabilities.borrow<&{DeFiActions.PriceOracle}>(/public/bandOraclePriceOracle)
    if oracleRef == nil {
        return nil
    }
    return oracleRef!.unitOfAccount().identifier
}
