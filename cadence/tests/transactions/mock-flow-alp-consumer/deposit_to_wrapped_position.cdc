import "FungibleToken"

import "FungibleTokenConnectors"

import "MOET"
import "FlowALPv1"
import "MockFlowALPv1Consumer"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Deposits the amount of the Vault at the signer's StoragePath to the wrapped position
///
transaction(amount: UFix64, vaultStoragePath: StoragePath, pushToDrawDownSink: Bool) {
    
    // the funds that will be used as collateral for a FlowALPv1 loan
    let collateral: @{FungibleToken.Vault}
    // the position to deposit to (requires EParticipant entitlement for deposit)
    let position: auth(FlowALPv1.EParticipant) &FlowALPv1.Position

    prepare(signer: auth(BorrowValue) &Account) {
        // withdraw the collateral from the signer's stored Vault
        let collateralSource = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: vaultStoragePath)
            ?? panic("Could not borrow reference to Vault from \(vaultStoragePath)")
        self.collateral <- collateralSource.withdraw(amount: amount)
        // reference the wrapped position
        self.position = signer.storage.borrow<&MockFlowALPv1Consumer.PositionWrapper>(
                from: MockFlowALPv1Consumer.WrapperStoragePath
            )?.borrowPositionForDeposit()
            ?? panic("Could not find a WrappedPosition in signer's storage at \(MockFlowALPv1Consumer.WrapperStoragePath)")
    }

    execute {
        // deposit to the position
        self.position.depositAndPush(from: <-self.collateral, pushToDrawDownSink: pushToDrawDownSink)
    }
}
