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
    // the manager to access the position (requires EPositionDeposit entitlement for deposit)
    let manager: auth(FlowCreditMarket.EPositionDeposit) &FlowCreditMarket.PositionManager
    let positionId: UInt64

    prepare(signer: auth(BorrowValue) &Account) {
        // withdraw the collateral from the signer's stored Vault
        let collateralSource = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: vaultStoragePath)
            ?? panic("Could not borrow reference to Vault from \(vaultStoragePath)")
        self.collateral <- collateralSource.withdraw(amount: amount)
        // Borrow the PositionManager from constant storage path with deposit entitlement
        self.manager = signer.storage.borrow<auth(FlowCreditMarket.EPositionDeposit) &FlowCreditMarket.PositionManager>(
                from: FlowCreditMarket.PositionStoragePath
            )
            ?? panic("Could not find PositionManager in signer's storage")
        self.positionId = positionId
    }

    execute {
        // deposit to the position via the manager
        self.manager.depositAndPush(pid: self.positionId, from: <-self.collateral, pushToDrawDownSink: pushToDrawDownSink)
    }
}
