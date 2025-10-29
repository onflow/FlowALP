// Repay MOET debt and withdraw collateral from a position
// 
// This transaction uses withdrawAndPull with pullFromTopUpSource: true to:
// 1. Automatically pull MOET from the user's vault to repay the debt
// 2. Withdraw and return the collateral to the user
//
// The MockTidalProtocolConsumer.PositionWrapper provides the necessary
// FungibleToken.Withdraw authorization through borrowPositionForWithdraw()
//
// After running this transaction:
// - MOET debt will be repaid (balance goes to 0) 
// - Flow collateral will be returned to the user's vault
// - The position will be empty (all balances at 0)

import "FungibleToken"
import "FlowToken"
import "DeFiActions"
import "TidalProtocol"
import "MockTidalProtocolConsumer"
import "MOET"

transaction(positionWrapperPath: StoragePath) {
    
    let positionRef: auth(FungibleToken.Withdraw) &TidalProtocol.Position
    let receiverRef: &{FungibleToken.Receiver}
    let moetWithdrawRef: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}
    
    prepare(borrower: auth(BorrowValue) &Account) {
        // Get wrapper reference
        let wrapperRef = borrower.storage.borrow<&MockTidalProtocolConsumer.PositionWrapper>(
            from: positionWrapperPath
        ) ?? panic("Could not borrow reference to position wrapper")
        
        // Get position reference with withdraw authorization
        self.positionRef = wrapperRef.borrowPositionForWithdraw()
        
        // Get receiver reference for depositing withdrawn collateral
        self.receiverRef = borrower.capabilities.borrow<&{FungibleToken.Receiver}>(
            /public/flowTokenReceiver
        ) ?? panic("Could not borrow receiver reference to the recipient's Vault")

        // Borrow withdraw reference to borrower's MOET vault to repay debt
        self.moetWithdrawRef = borrower.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: MOET.VaultStoragePath)
            ?? panic("No MOET vault in storage")
    }
    
    execute {
        // Repay all MOET debt without requiring EParticipant: use a Sink and depositCapacity
        if self.moetWithdrawRef.balance > 0.0 {
            let sink: {DeFiActions.Sink} = self.positionRef.createSink(type: Type<@MOET.Vault>())
            sink.depositCapacity(from: self.moetWithdrawRef)
        }

        // Now withdraw all available Flow collateral without top-up assistance
        let withdrawAmount = self.positionRef.availableBalance(
            type: Type<@FlowToken.Vault>(),
            pullFromTopUpSource: false
        )
        let withdrawnVault <- self.positionRef.withdrawAndPull(
            type: Type<@FlowToken.Vault>(),
            amount: withdrawAmount,
            pullFromTopUpSource: false
        )
        
        // Deposit withdrawn collateral to user's vault
        self.receiverRef.deposit(from: <-withdrawnVault)
    }
} 