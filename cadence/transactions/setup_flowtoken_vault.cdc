import FlowToken from "FlowToken"
import FungibleToken from "FungibleToken"

transaction {
    prepare(signer: auth(SaveValue, BorrowValue, IssueStorageCapabilityController, PublishCapability) &Account) {
        if signer.storage.borrow<&FlowToken.Vault>(from: /storage/flowTokenVault) != nil {
            return
        }
        
        let vault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        signer.storage.save(<-vault, to: /storage/flowTokenVault)
        
        let vaultCap = signer.capabilities.storage.issue<&FlowToken.Vault>(
            /storage/flowTokenVault
        )
        signer.capabilities.publish(vaultCap, at: /public/flowTokenReceiver)
    }
} 