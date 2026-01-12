import "FlowCreditMarket"
import "FungibleToken"
import "MOET"
import "MockDexSwapper"
import "DeFiActions"

/// Test transaction to configure a MockDexSwapper as the insurance swapper for a token.
/// The swapper will convert the specified token type to MOET using the provided price ratio.
///
/// @param tokenTypeIdentifier: The token type to configure (e.g., "A.0x07.MOET.Vault")
/// @param priceRatio: Output MOET per unit of input token (e.g., 1.0 for 1:1)
transaction(tokenTypeIdentifier: String, priceRatio: UFix64) {
    let pool: auth(FlowCreditMarket.EGovernance) &FlowCreditMarket.Pool
    let tokenType: Type
    let moetVaultCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>

    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController) &Account) {
        self.pool = signer.storage.borrow<auth(FlowCreditMarket.EGovernance) &FlowCreditMarket.Pool>(
            from: FlowCreditMarket.PoolStoragePath
        ) ?? panic("Could not borrow Pool at \(FlowCreditMarket.PoolStoragePath)")

        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier: \(tokenTypeIdentifier)")

        // Issue a capability to the signer's MOET vault for the swapper to withdraw from
        self.moetVaultCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(
            MOET.VaultStoragePath
        )
    }

    execute {
        let swapper = MockDexSwapper.Swapper(
            inVault: self.tokenType,
            outVault: Type<@MOET.Vault>(),
            vaultSource: self.moetVaultCap,
            priceRatio: priceRatio,
            uniqueID: nil
        )
        self.pool.setInsuranceSwapper(tokenType: self.tokenType, swapper: swapper)
    }
}
