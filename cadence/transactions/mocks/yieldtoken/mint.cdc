import "FungibleToken"

import "MockYieldToken"

/// Mints MockYieldToken using the Minter stored in the signer's account and deposits to the recipients MockYieldToken Vault. If the
/// recipient's MockYieldToken Vault is not configured with a public Capability or the signer does not have a MOET Minter
/// stored, the transaction will revert.
///
/// @param to: The recipient's Flow address
/// @param amount: How many MockYieldToken tokens to mint to the recipient's account
///
transaction(to: Address, amount: UFix64) {

    let receiver: &{FungibleToken.Vault}
    let minter: &MockYieldToken.Minter

    prepare(signer: auth(BorrowValue) &Account) {
        self.minter = signer.storage.borrow<&MockYieldToken.Minter>(from: MockYieldToken.AdminStoragePath)
            ?? panic("Could not borrow reference to MOET Minter from signer's account at path \(MockYieldToken.AdminStoragePath)")
        self.receiver = getAccount(to).capabilities.borrow<&{FungibleToken.Vault}>(MockYieldToken.VaultPublicPath)
            ?? panic("Could not borrow reference to MOET Vault from recipient's account at path \(MockYieldToken.VaultPublicPath)")
    }

    execute {
        self.receiver.deposit(
            from: <-self.minter.mintTokens(amount: amount)
        )
    }
}
