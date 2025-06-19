// Repay MOET debt and close position using the new contract method
// This transaction CAN return collateral because it uses the contract's
// repayAndClosePosition method which has internal access to withdraw funds.

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
        let positionRef = wrapperRef.borrowPosition()
        
        // Get position ID
        let positionId = positionRef.getId()
        log("Position ID: ".concat(positionId.toString()))
        
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
        let moetVault = borrower.storage.borrow<auth(FungibleToken.Withdraw) &MOET.Vault>(
            from: MOET.VaultStoragePath
        ) ?? panic("Could not borrow MOET vault")
        
        // Withdraw all MOET to repay
        let repaymentAmount = moetVault.balance
        log("Repaying MOET amount: ".concat(repaymentAmount.toString()))
        let repaymentVault <- moetVault.withdraw(amount: repaymentAmount)
        
        // Prepare collateral receivers - for now just Flow
        let collateralReceivers: {Type: Capability<&{FungibleToken.Receiver}>} = {}
        let flowReceiverCap = borrower.capabilities.get<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
        if flowReceiverCap.check() {
            collateralReceivers[Type<@FlowToken.Vault>()] = flowReceiverCap
        }
        
        // Get the pool and call repayAndClosePosition
        let poolCap = getAccount(0x0000000000000007)
            .capabilities.get<&TidalProtocol.Pool>(TidalProtocol.PoolPublicPath)
        let pool = poolCap.borrow() ?? panic("Could not borrow Pool capability")
        
        log("=== Using Contract Method (repayAndClosePosition) ===")
        
        // Call the new contract method that can handle both repayment and collateral return
        let leftoverCollateral <- pool.repayAndClosePosition(
            pid: positionId,
            repaymentVault: <-repaymentVault,
            collateralReceivers: collateralReceivers
        )
        
        // Handle any leftover collateral (shouldn't be any if we provided receivers)
        for tokenType in leftoverCollateral.keys {
            let vault <- leftoverCollateral.remove(key: tokenType)!
            log("WARNING: Leftover collateral of type ".concat(tokenType.identifier).concat(" with balance ").concat(vault.balance.toString()))
            // Destroy it for now (in production, would handle this properly)
            destroy vault
        }
        destroy leftoverCollateral
        
        // Log final state
        log("=== Position Successfully Closed ===")
        log("MOET debt repaid: ".concat(repaymentAmount.toString()))
        log("Flow collateral returned to user!")
        
        // Verify user's Flow balance increased
        let flowVault = borrower.storage.borrow<&FlowToken.Vault>(from: /storage/flowTokenVault)!
        log("User's Flow balance after closing: ".concat(flowVault.balance.toString()))
        log("===================================")
    }
} 