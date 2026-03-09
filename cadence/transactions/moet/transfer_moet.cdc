import MOET from "MOET"
import FungibleToken from "FungibleToken"

transaction(recipient: Address, amount: UFix64) {
    prepare(signer: auth(BorrowValue) &Account) {
        let vault = signer.storage.borrow<auth(FungibleToken.Withdraw) &MOET.Vault>(from: MOET.VaultStoragePath)
            ?? panic("Could not borrow MOET vault")
        let receiver = getAccount(recipient).capabilities.borrow<&{FungibleToken.Receiver}>(MOET.VaultPublicPath)
            ?? panic("Could not borrow MOET receiver")
        receiver.deposit(from: <-vault.withdraw(amount: amount))
    }
}
