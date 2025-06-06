import "FungibleToken"

import "DFB"
import "FungibleTokenStack"

import "MOET"
import "MockTidalProtocolConsumer"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Opens a Position with the amount of funds source from the Vault at the provided StoragePath and wraps it in a
/// MockTidalProtocolConsumer PositionWrapper
///
transaction(amount: UFix64, vaultStoragePath: StoragePath, pushToDrawDownSink: Bool) {
    
    // the funds that will be used as collateral for a TidalProtocol loan
    let collateral: @{FungibleToken.Vault}
    // this DeFiBlocks Sink that will receive the loaned funds
    let sink: {DFB.Sink}
    // the signer's account in which to store a PositionWrapper
    let account: auth(SaveValue) &Account

    prepare(signer: auth(BorrowValue, SaveValue, IssueStorageCapabilityController, PublishCapability, UnpublishCapability) &Account) {
        // configure a MOET Vault to receive the loaned amount
        if signer.storage.type(at: MOET.VaultStoragePath) == nil {
            // save a new MOET Vault
            signer.storage.save(<-MOET.createEmptyVault(vaultType: Type<@MOET.Vault>()), to: MOET.VaultStoragePath)
            // issue un-entitled Capability
            let vaultCap = signer.capabilities.storage.issue<&MOET.Vault>(MOET.VaultStoragePath)
            // publish receiver Capability, unpublishing any that may exist to prevent collision
            signer.capabilities.unpublish(MOET.VaultPublicPath)
            signer.capabilities.publish(vaultCap, at: MOET.VaultPublicPath)
        }
        // assign a Vault Capability to be used in the VaultSink
        let depositVault = signer.capabilities.get<&{FungibleToken.Vault}>(MOET.VaultPublicPath)
        assert(depositVault.check(),
            message: "Invalid MOET Vault Capability issued - ensure the Vault is properly configured")
        
        // withdraw the collateral from the signer's stored Vault
        let collateralSource = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: vaultStoragePath)
            ?? panic("Could not borrow reference to Vault from \(vaultStoragePath)")
        self.collateral <- collateralSource.withdraw(amount: amount)
        // construct the DeFiBlocks Sink that will receive the loaned amount
        self.sink = FungibleTokenStack.VaultSink(
            max: nil,
            depositVault: depositVault,
            uniqueID: nil
        )

        // assign the signer's account enabling the execute block to save the wrapper
        self.account = signer
    }

    execute {
        // open a position & save in the Wrapper
        let wrapper <- MockTidalProtocolConsumer.createPositionWrapper(
            collateral: <-self.collateral,
            issuanceSink: self.sink,
            repaymentSource: nil,
            pushToDrawDownSink: pushToDrawDownSink
        )
        // save the wrapper into the signer's account - reverts on storage collision
        self.account.storage.save(<-wrapper, to: MockTidalProtocolConsumer.WrapperStoragePath)
    }
}
