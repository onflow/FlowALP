import "FlowCreditMarket"
import "DeFiActions"

/// Configure or remove the insurance swapper for a token type.
/// The insurance swapper converts collected reserve funds into MOET for the insurance fund.
///
/// @param tokenTypeIdentifier: The token type to configure (e.g., "A.0x07.MOET.Vault")
/// @param swapper: The swapper to use for insurance collection, or nil to remove the swapper
transaction(
    tokenTypeIdentifier: String,
    swapper: {DeFiActions.Swapper}?,
) {
    let pool: auth(FlowCreditMarket.EGovernance) &FlowCreditMarket.Pool
    let tokenType: Type

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowCreditMarket.EGovernance) &FlowCreditMarket.Pool>(from: FlowCreditMarket.PoolStoragePath)
            ?? panic("Could not borrow Pool at \(FlowCreditMarket.PoolStoragePath)")
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")
    }

    execute {
        self.pool.setInsuranceSwapper(tokenType: self.tokenType, swapper: swapper)
    }
}