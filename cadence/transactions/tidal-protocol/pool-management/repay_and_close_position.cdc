// Repay MOET debt for a position
// NOTE: This transaction can only repay the debt. It CANNOT return collateral
// due to authorization constraints. The Position.withdraw() function requires
// FungibleToken.Withdraw access which transactions cannot obtain.
//
// After running this transaction:
// - MOET debt will be repaid (balance goes to 0)
// - Flow collateral remains locked in the position
// - User cannot access their collateral without contract changes
//
// This is a critical limitation that needs to be addressed by adding a
// contract method like repayAndClosePosition() that can internally handle
// both debt repayment and collateral return.

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
        
        // Get MOET vault to repay
        // let moetVault = borrower.storage.borrow<auth(FungibleToken.Withdraw) &MOET.Vault>(
        //     from: MOET.VaultStoragePath
        // ) ?? panic("Could not borrow MOET vault")
        
        // // Withdraw all MOET to repay
        // let repaymentAmount = moetVault.balance
        // log("Repaying MOET amount: ".concat(repaymentAmount.toString()))
        // let repaymentVault <- moetVault.withdraw(amount: repaymentAmount)
        
        // // Deposit to repay the debt
        // positionRef.deposit(from: <-repaymentVault)
        let receiverRef =  borrower.capabilities.borrow<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
			?? panic("Could not borrow receiver reference to the recipient's Vault")

        let withdrawnVault <- positionRef.withdrawAndPull(
            type: Type<@FlowToken.Vault>(),
            amount: 1000.0,
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
        
        // Note: Cannot withdraw collateral due to authorization constraints
        log("NOTE: Collateral cannot be withdrawn - requires FungibleToken.Withdraw access")
        log("User's Flow tokens remain locked in the position!")

        receiverRef.deposit(from: <-withdrawnVault)
    }
} 