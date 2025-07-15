import FlowToken from "FlowToken"
import FungibleToken from "FungibleToken"

// Transfers FLOW tokens from signer (service account) to recipient
transaction(recipient: Address, amount: UFix64) {
    prepare(signer: auth(BorrowValue) &Account) {
        let vaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("Could not borrow FlowToken vault ref from signer")

        let receiverRef = getAccount(recipient)
            .capabilities.borrow<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
            ?? panic("Could not borrow receiver reference")

        let sentVault <- vaultRef.withdraw(amount: amount)
        receiverRef.deposit(from: <- sentVault)
    }
} 