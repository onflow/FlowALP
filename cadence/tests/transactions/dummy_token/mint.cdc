import "DummyToken"
import "FungibleToken"

transaction(amount: UFix64, recipient: Address) {
    prepare(signer: auth(Storage) &Account) {
        let minter = signer.storage.borrow<&DummyToken.Minter>(from: DummyToken.AdminStoragePath)
            ?? panic("Could not borrow minter")

        let tokens <- minter.mintTokens(amount: amount)

        let receiverRef = getAccount(recipient)
            .capabilities.borrow<&{FungibleToken.Receiver}>(DummyToken.ReceiverPublicPath)
            ?? panic("Could not borrow receiver")

        receiverRef.deposit(from: <-tokens)
    }
}
