import "FlowALPv0"
import "FlowALPModels"
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
    let pool: auth(FlowALPModels.EGovernance) &FlowALPv0.Pool
    let tokenType: Type

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALPModels.EGovernance) &FlowALPv0.Pool>(from: FlowALPv0.PoolStoragePath)
            ?? panic("Could not borrow Pool at \(FlowALPv0.PoolStoragePath)")
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")
    }

    execute {
        self.pool.setInsuranceSwapper(tokenType: self.tokenType, swapper: swapper)
    }
}
