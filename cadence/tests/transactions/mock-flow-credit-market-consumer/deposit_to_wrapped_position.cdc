import "FungibleToken"

import "FungibleTokenConnectors"

import "MOET"
import "FlowCreditMarket"
import "MockFlowCreditMarketConsumer"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Deposits the amount of the Vault at the signer's StoragePath to the position
///
transaction(positionId: UInt64, amount: UFix64, vaultStoragePath: StoragePath, pushToDrawDownSink: Bool) {

    // the funds that will be used as collateral for a FlowCreditMarket loan
    let collateral: @{FungibleToken.Vault}
    // the position to deposit to (requires EPositionDeposit entitlement for deposit)
    let position: auth(FlowCreditMarket.EPositionDeposit) &FlowCreditMarket.Position

    prepare(signer: auth(BorrowValue) &Account) {
        // withdraw the collateral from the signer's stored Vault
        let collateralSource = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: vaultStoragePath)
            ?? panic("Could not borrow reference to Vault from \(vaultStoragePath)")
        self.collateral <- collateralSource.withdraw(amount: amount)
        // Borrow the Position resource directly from storage with deposit entitlement
        let storagePath = FlowCreditMarket.getPositionStoragePath(pid: positionId)
        self.position = signer.storage.borrow<auth(FlowCreditMarket.EPositionDeposit) &FlowCreditMarket.Position>(
                from: storagePath
            )
            ?? panic("Could not find Position with ID \(positionId) in signer's storage at \(storagePath.toString())")
    }

    execute {
        // deposit to the position
        self.position.depositAndPush(from: <-self.collateral, pushToDrawDownSink: pushToDrawDownSink)
    }
}
