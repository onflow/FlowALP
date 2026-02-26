import "FungibleToken"

import "FungibleTokenConnectors"

import "MOET"
import "FlowALPv0"
import "FlowALPPositionResources"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Deposits the amount of the Vault at the signer's StoragePath to the position
///
transaction(positionID: UInt64, amount: UFix64, vaultStoragePath: StoragePath, pushToDrawDownSink: Bool) {

    // the funds that will be used as collateral for a FlowALPv0 loan
    let collateral: @{FungibleToken.Vault}
    let position: &FlowALPPositionResources.Position
    let pushToDrawDownSink: Bool

    prepare(signer: auth(BorrowValue) &Account) {
        // withdraw the collateral from the signer's stored Vault
        let collateralSource = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: vaultStoragePath)
            ?? panic("Could not borrow reference to Vault from \(vaultStoragePath)")
        self.collateral <- collateralSource.withdraw(amount: amount)

        // Borrow the PositionManager from constant storage path
        let manager = signer.storage.borrow<&FlowALPPositionResources.PositionManager>(
                from: FlowALPv0.PositionStoragePath
            )
            ?? panic("Could not find PositionManager in signer's storage")

        // Borrow the specified position
        self.position = manager.borrowPosition(pid: positionID)
        self.pushToDrawDownSink = pushToDrawDownSink
    }

    execute {
        // deposit to the position directly
        self.position.depositAndPush(from: <-self.collateral, pushToDrawDownSink: self.pushToDrawDownSink)
    }
}
