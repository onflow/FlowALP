import "FlowCreditMarket"
import "FungibleToken"
import "MOET"
import "MockDexSwapper"
import "DeFiActions"

/// TEST-ONLY: Test transaction to configure a MockDexSwapper as the insurance swapper for a token.
/// The swapper will convert the specified swapperIn type to swapperOut type using the provided price ratio.
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
    let pool: auth(FlowCreditMarket.EGovernance) &FlowCreditMarket.Pool
    let tokenType: Type
    let swapperInType: Type
    let swapperOutType: Type
    let moetVaultCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>

    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController) &Account) {
        self.pool = signer.storage.borrow<auth(FlowCreditMarket.EGovernance) &FlowCreditMarket.Pool>(
            from: FlowCreditMarket.PoolStoragePath
        ) ?? panic("Could not borrow Pool at \(FlowCreditMarket.PoolStoragePath)")

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
