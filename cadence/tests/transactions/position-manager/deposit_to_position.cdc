import "FungibleToken"

import "FungibleTokenConnectors"

import "MOET"
import "FlowCreditMarket"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Deposits the amount of the Vault at the signer's StoragePath to the position
///
transaction(amount: UFix64, vaultStoragePath: StoragePath, pushToDrawDownSink: Bool) {

    // the funds that will be used as collateral for a FlowCreditMarket loan
    let collateral: @{FungibleToken.Vault}
    // the position to deposit to (requires EPositionDeposit entitlement)
    let position: auth(FlowCreditMarket.EPositionDeposit) &FlowCreditMarket.Position
    let pushToDrawDownSink: Bool

    prepare(signer: auth(BorrowValue) &Account) {
        // withdraw the collateral from the signer's stored Vault
        let collateralSource = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: vaultStoragePath)
            ?? panic("Could not borrow reference to Vault from \(vaultStoragePath)")
        self.collateral <- collateralSource.withdraw(amount: amount)

        // Borrow the PositionManager from constant storage path
        let manager = signer.storage.borrow<auth(FlowCreditMarket.EPositionDeposit) &FlowCreditMarket.PositionManager>(
                from: FlowCreditMarket.PositionStoragePath
            )
            ?? panic("Could not find PositionManager in signer's storage")

        // Get the first (and typically only) position ID
        let positionIDs = manager.getPositionIDs()
        if positionIDs.length == 0 {
            panic("No positions found in PositionManager")
        }
        let positionId = positionIDs[0]

        // Borrow the position with deposit entitlement
        self.position = manager.borrowAuthorizedPosition(pid: positionId)
        self.pushToDrawDownSink = pushToDrawDownSink
    }

    execute {
        // deposit to the position directly
        self.position.depositAndPush(from: <-self.collateral, pushToDrawDownSink: self.pushToDrawDownSink)
    }
}
