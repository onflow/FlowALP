import MOET from "MOET"
import FungibleToken from "FungibleToken"

transaction {
    prepare(signer: auth(SaveValue, BorrowValue, IssueStorageCapabilityController, PublishCapability) &Account) {
        // Check if vault already exists
        if signer.storage.borrow<&MOET.Vault>(from: /storage/moetVault) != nil {
            return
        }
        
        // Create a new vault
        let vault <- MOET.createEmptyVault(vaultType: Type<@MOET.Vault>())
        
        // Save it to storage
        signer.storage.save(<-vault, to: /storage/moetVault)
        
        // Create capabilities
        let vaultCap = signer.capabilities.storage.issue<&MOET.Vault>(
            /storage/moetVault
        )
        
        // Publish receiver capability
        signer.capabilities.publish(
            vaultCap,
            at: /public/moetReceiver
        )
    }
} 