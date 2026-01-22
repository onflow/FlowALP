import "FlowCreditMarket"

/// Sets the liquidation bonus for a supported token type.
/// The bonus is expressed as a fractional rate (e.g., 0.05 for 5%).
///
/// @param tokenTypeIdentifier: e.g., "A.0000000000000003.FlowToken.Vault"
/// @param bonus: fractional rate between 0.0 and 1.0
transaction(tokenTypeIdentifier: String, bonus: UFix64) {
    let tokenType: Type
    let pool: auth(FlowCreditMarket.EGovernance) &FlowCreditMarket.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")
        self.pool = signer.storage.borrow<auth(FlowCreditMarket.EGovernance) &FlowCreditMarket.Pool>(from: FlowCreditMarket.PoolStoragePath)
            ?? panic("Could not borrow reference to Pool from \(FlowCreditMarket.PoolStoragePath)")
    }

    execute {
        self.pool.setTokenLiquidationBonus(tokenType: self.tokenType, bonus: bonus)
    }
}
