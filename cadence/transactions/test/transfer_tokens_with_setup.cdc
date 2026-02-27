import FungibleToken from "FungibleToken"

/// Transfer tokens from holder to recipient
/// Sets up recipient's vault if it doesn't exist
transaction(amount: UFix64, vaultPath: StoragePath) {
    prepare(holder: auth(BorrowValue, Storage) &Account, recipient: auth(BorrowValue, Storage, Capabilities) &Account) {

        log("\(holder.address.toString())")
        // Borrow holder's vault
        let holderVault = holder.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: vaultPath)
            ?? panic("Could not borrow holder vault")

        // Setup recipient's vault if it doesn't exist
        if recipient.storage.borrow<&{FungibleToken.Vault}>(from: vaultPath) == nil {
            // Create empty vault
            let emptyVault <- holderVault.withdraw(amount: 0.0)
            recipient.storage.save(<-emptyVault, to: vaultPath)

            // Create and publish public capability
            let pathIdentifier = vaultPath.toString().slice(from: 9, upTo: vaultPath.toString().length)
            let publicPath = PublicPath(identifier: pathIdentifier)!
            let cap = recipient.capabilities.storage.issue<&{FungibleToken.Receiver}>(vaultPath)
            recipient.capabilities.publish(cap, at: publicPath)
        }

        // Transfer tokens
        let recipientVault = recipient.storage.borrow<&{FungibleToken.Receiver}>(from: vaultPath)!
        let tokens <- holderVault.withdraw(amount: amount)
        recipientVault.deposit(from: <-tokens)
    }
}
