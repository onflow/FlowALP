import "DummyToken"
import "FungibleToken"

transaction {
    prepare(signer: auth(Storage, Capabilities) &Account) {
        if signer.storage.borrow<&DummyToken.Vault>(from: DummyToken.VaultStoragePath) == nil {
            signer.storage.save(<-DummyToken.createEmptyVault(vaultType: Type<@DummyToken.Vault>()), to: DummyToken.VaultStoragePath)

            let cap = signer.capabilities.storage.issue<&DummyToken.Vault>(DummyToken.VaultStoragePath)
            signer.capabilities.publish(cap, at: DummyToken.VaultPublicPath)
            signer.capabilities.publish(cap, at: DummyToken.ReceiverPublicPath)
        }
    }
}
