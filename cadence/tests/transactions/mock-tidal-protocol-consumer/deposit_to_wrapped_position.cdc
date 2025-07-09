import "FungibleToken"

import "DFB"
import "FungibleTokenStack"

import "MOET"
import "TidalProtocol"
import "MockTidalProtocolConsumer"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Deposits the amount of the Vault at the signer's StoragePath to the wrapped position
///
transaction(amount: UFix64, vaultStoragePath: StoragePath, pushToDrawDownSink: Bool) {
    
    // the funds that will be used as collateral for a TidalProtocol loan
    let collateral: @{FungibleToken.Vault}
    // the position to deposit to
    let position: &TidalProtocol.Position

    prepare(signer: auth(BorrowValue) &Account) {
        // withdraw the collateral from the signer's stored Vault
        let collateralSource = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: vaultStoragePath)
            ?? panic("Could not borrow reference to Vault from \(vaultStoragePath)")
        self.collateral <- collateralSource.withdraw(amount: amount)
        // reference the wrapped position
        self.position = signer.storage.borrow<&MockTidalProtocolConsumer.PositionWrapper>(
                from: MockTidalProtocolConsumer.WrapperStoragePath
            )?.borrowPosition()
            ?? panic("Could not find a WrappedPosition in signer's storage at \(MockTidalProtocolConsumer.WrapperStoragePath)")
    }

    execute {
        // deposit to the position
        self.position.depositAndPush(from: <-self.collateral, pushToDrawDownSink: pushToDrawDownSink)
    }
}
