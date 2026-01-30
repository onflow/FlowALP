import "FungibleToken"

import "MockYieldToken"

/// Creates & stores a MockYieldToken Vault in the signer's account, also configuring its public Vault Capability
///
transaction {

    prepare(signer: auth(BorrowValue, SaveValue, IssueStorageCapabilityController, PublishCapability, UnpublishCapability) &Account) {
        // configure if nothing is found at canonical path
        if signer.storage.type(at: MockYieldToken.VaultStoragePath) == nil {
            // save the new vault
            signer.storage.save(<-MockYieldToken.createEmptyVault(vaultType: Type<@MockYieldToken.Vault>()), to: MockYieldToken.VaultStoragePath)
            // publish a public capability on the Vault
            let cap = signer.capabilities.storage.issue<&{FungibleToken.Vault}>(MockYieldToken.VaultStoragePath)
            signer.capabilities.unpublish(MockYieldToken.VaultPublicPath)
            signer.capabilities.unpublish(MockYieldToken.ReceiverPublicPath)
            signer.capabilities.publish(cap, at: MockYieldToken.VaultPublicPath)
            signer.capabilities.publish(cap, at: MockYieldToken.ReceiverPublicPath)
            // issue an authorized capability to initialize a CapabilityController on the account, but do not publish
            signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(MockYieldToken.VaultStoragePath)
        }

        // ensure proper configuration
        if signer.storage.type(at: MockYieldToken.VaultStoragePath) != Type<@MockYieldToken.Vault>(){
            panic("Could not configure MockYieldToken Vault at \(MockYieldToken.VaultStoragePath) - check for collision and try again")
        }
    }
}
