import "FungibleToken"
import "MockDexSwapper"

/// TEST-ONLY: Adds a swapper to MockDexSwapper for a specific token pair
///
/// @param inVaultIdentifier: The input Vault's Type identifier (e.g., Type<@FlowToken.Vault>().identifier)
/// @param outVaultIdentifier: The output Vault's Type identifier (e.g., Type<@MOET.Vault>().identifier)
/// @param vaultSourceStoragePath: The storage path of the vault to use as the output source (from signer's storage)
/// @param priceRatio: The price ratio for the swap (out per unit in)
transaction(
    inVaultIdentifier: String,
    outVaultIdentifier: String,
    vaultSourceStoragePath: StoragePath,
    priceRatio: UFix64
) {
    let inType: Type
    let outType: Type
    let vaultSourceCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>

    prepare(signer: auth(IssueStorageCapabilityController) &Account) {
        self.inType = CompositeType(inVaultIdentifier) ?? panic("Invalid inVaultIdentifier \(inVaultIdentifier)")
        self.outType = CompositeType(outVaultIdentifier) ?? panic("Invalid outVaultIdentifier \(outVaultIdentifier)")

        // Get a capability to the vault source from the signer's storage
        self.vaultSourceCap = signer.capabilities.storage
            .issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(vaultSourceStoragePath)

        assert(self.vaultSourceCap.check(), message: "Invalid vault source capability")
    }

    execute {
        // Create the swapper
        let swapper = MockDexSwapper.Swapper(
            inVault: self.inType,
            outVault: self.outType,
            vaultSource: self.vaultSourceCap,
            priceRatio: priceRatio,
            uniqueID: nil
        )

        // Add the swapper to MockDexSwapper
        MockDexSwapper._addSwapper(swapper: swapper)
    }
}
