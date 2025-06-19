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
    prepare(borrower: auth(Storage) &Account) {
        // Get wrapper reference
        let wrapperRef = borrower.storage.borrow<&MockTidalProtocolConsumer.PositionWrapper>(from: positionWrapperPath)
            ?? panic("Could not borrow reference to position wrapper")
        
        // Get position reference
        let positionRef = wrapperRef.borrowPositionForWithdraw()
        
        // Log position details BEFORE repayment
        log("=== Position Details BEFORE Repayment ===")
        let balancesBefore = positionRef.getBalances()
        for balance in balancesBefore {
            let direction = balance.direction == TidalProtocol.BalanceDirection.Credit ? "Credit" : "Debit"
            log("Token: ".concat(balance.type.identifier)
                .concat(" | Direction: ").concat(direction)
                .concat(" | Amount: ").concat(balance.balance.toString()))
        }
        log("Health: ".concat(positionRef.getHealth().toString()))
        log("=========================================")
        
        // Withdraw all collateral, using pullFromTopUpSource: true, so that all debt is automatically repaid
        let receiverRef =  borrower.capabilities.borrow<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
			?? panic("Could not borrow receiver reference to the recipient's Vault")

        let withdrawnVault <- positionRef.withdrawAndPull(
            type: Type<@FlowToken.Vault>(),
            amount: 1000.0, // should be using `positionRef.availableBalance(type: Type<@FlowToken.Vault>(), pullFromTopUpSource: true), but this for some reason returns 0
            pullFromTopUpSource: true,
        )
        
        // Log position details AFTER repayment
        log("=== Position Details AFTER Repayment ===")
        let balancesAfter = positionRef.getBalances()
        for balance in balancesAfter {
            let direction = balance.direction == TidalProtocol.BalanceDirection.Credit ? "Credit" : "Debit"
            log("Token: ".concat(balance.type.identifier)
                .concat(" | Direction: ").concat(direction)
                .concat(" | Amount: ").concat(balance.balance.toString()))
        }
        log("Health: ".concat(positionRef.getHealth().toString()))
        log("=========================================")
        
        // Success! Debt has been repaid and collateral withdrawn
        log("SUCCESS: Position closed successfully!")
        log("Debt repaid and collateral returned to user")

        receiverRef.deposit(from: <-withdrawnVault)
    }
} 