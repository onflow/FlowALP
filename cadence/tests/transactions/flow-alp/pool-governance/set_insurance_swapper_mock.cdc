import "FlowALPv0"
import "FungibleToken"
import "MOET"
import "MockDexSwapper"
import "DeFiActions"

/// TEST-ONLY: Test transaction to configure a MockDexSwapper as the insurance swapper for a token.
///
/// This transaction intentionally allows specifying arbitrary swapper input
/// and output types in order to test validation and failure cases in
/// `setInsuranceSwapper`, such as:
/// - mismatched input token types
/// - non-MOET output token types
///
/// In production usage, insurance swappers are always expected to swap
/// *to* MOET. The additional parameters exist solely to enable negative
/// test coverage and are not intended as supported behavior.
///
/// @param tokenTypeIdentifier: The token type to configure (e.g., "A.0x07.MOET.Vault")
/// @param priceRatio: Output tokens per unit of input token (e.g., 1.0 for 1:1)
/// @param swapperInTypeIdentifier: The input token type for the swapper
/// @param swapperOutTypeIdentifier: The output token type for the swapper (must be MOET for insurance)
transaction(
    tokenTypeIdentifier: String, 
    priceRatio: UFix64,
    swapperInTypeIdentifier: String,
    swapperOutTypeIdentifier: String
) {
    let pool: auth(FlowALPv0.EGovernance) &FlowALPv0.Pool
    let tokenType: Type
    let swapperInType: Type
    let swapperOutType: Type
    let moetVaultCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>

    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALPv0.EGovernance) &FlowALPv0.Pool>(
            from: FlowALPv0.PoolStoragePath
        ) ?? panic("Could not borrow Pool at \(FlowALPv0.PoolStoragePath)")

        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier: \(tokenTypeIdentifier)")
        self.swapperInType = CompositeType(swapperInTypeIdentifier)
            ?? panic("Invalid swapperInTypeIdentifier: \(swapperInTypeIdentifier)")
        self.swapperOutType = CompositeType(swapperOutTypeIdentifier)
            ?? panic("Invalid swapperOutTypeIdentifier: \(swapperOutTypeIdentifier)")        

        // Issue a capability to the signer's MOET vault for the swapper to withdraw from
        self.moetVaultCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(
            MOET.VaultStoragePath
        )
    }

    execute {
        let swapper = MockDexSwapper.Swapper(
            inVault: self.swapperInType,
            outVault: self.swapperOutType,
            vaultSource: self.moetVaultCap,
            priceRatio: priceRatio,
            uniqueID: nil
        )
        self.pool.setInsuranceSwapper(tokenType: self.tokenType, swapper: swapper)
    }
}
