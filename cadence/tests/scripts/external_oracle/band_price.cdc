import "DeFiActions"

/// Borrows the Band oracle as DeFiActions.PriceOracle at
/// /public/bandOraclePriceOracle (created by create_band_empty_fee.cdc)
/// and returns the price of the given token type.
access(all) fun main(ownerAddress: Address, ofToken: Type): UFix64? {
    let oracleRef = getAccount(ownerAddress).capabilities.borrow<&{DeFiActions.PriceOracle}>(/public/bandOraclePriceOracle)
    if oracleRef == nil {
        return nil
    }
    return oracleRef!.price(ofToken: ofToken)
}
