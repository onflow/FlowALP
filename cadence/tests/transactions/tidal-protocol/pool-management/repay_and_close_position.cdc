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
import "TidalProtocol"
import "MockTidalProtocolConsumer"
import "MOET"

transaction(positionWrapperPath: StoragePath) {
    
    let positionRef: auth(FungibleToken.Withdraw) &TidalProtocol.Position
    let receiverRef: &{FungibleToken.Receiver}
    
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
    }
    
    execute {
        // Withdraw all available collateral, automatically repaying debt via pullFromTopUpSource
        let withdrawnVault <- self.positionRef.withdrawAndPull(
            type: Type<@FlowToken.Vault>(),
            amount: self.positionRef.availableBalance(
                type: Type<@FlowToken.Vault>(), 
                pullFromTopUpSource: true
            ),
            pullFromTopUpSource: true
        )
        
        // Deposit withdrawn collateral to user's vault
        self.receiverRef.deposit(from: <-withdrawnVault)
    }
} 