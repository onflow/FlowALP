// Repay MOET debt and close position, withdrawing all collateral
//
// This transaction uses the closePosition method to:
// 1. Repay all debt with provided MOET vault
// 2. Withdraw and return all collateral to the user
//
// After running this transaction:
// - MOET debt will be repaid (balance goes to 0)
// - All collateral will be returned to the user's vault
// - The position will be closed

import "FungibleToken"
import "FlowToken"
import "DeFiActions"
import "FlowALPv0"
import "MOET"

transaction(positionId: UInt64) {

    let position: auth(FungibleToken.Withdraw) &FlowALPv0.Position
    let flowReceiverRef: &{FungibleToken.Receiver}
    let moetReceiverRef: &{FungibleToken.Receiver}
    let moetWithdrawRef: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}

    prepare(borrower: auth(BorrowValue) &Account) {
        // Borrow the PositionManager from constant storage path with both required entitlements
        let manager = borrower.storage.borrow<auth(FungibleToken.Withdraw, FlowALPv0.EPositionAdmin) &FlowALPv0.PositionManager>(
            from: FlowALPv0.PositionStoragePath
        ) ?? panic("Could not find PositionManager in storage")

        // Borrow the position with withdraw entitlement
        self.position = manager.borrowAuthorizedPosition(pid: positionId) as! auth(FungibleToken.Withdraw) &FlowALPv0.Position

        // Get receiver references for depositing withdrawn collateral and overpayment
        self.flowReceiverRef = borrower.capabilities.borrow<&{FungibleToken.Receiver}>(
            /public/flowTokenReceiver
        ) ?? panic("Could not borrow Flow receiver reference")

        self.moetReceiverRef = borrower.capabilities.borrow<&{FungibleToken.Receiver}>(
            MOET.VaultPublicPath
        ) ?? panic("Could not borrow MOET receiver reference")

        // Borrow withdraw reference to borrower's MOET vault to repay debt
        self.moetWithdrawRef = borrower.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: MOET.VaultStoragePath)
            ?? panic("No MOET vault in storage")
    }

    execute {
        // Calculate exact MOET debt from position
        let debts = self.position.getTotalDebt()
        var moetDebt: UFix64 = 0.0
        for debt in debts {
            if debt.tokenType == Type<@MOET.Vault>() {
                moetDebt = debt.amount
                break
            }
        }

        // Withdraw exact MOET debt amount (rounded up by getTotalDebt)
        // No buffer needed - contract now properly flips to credit when debt == 0
        let repaymentVaults: @[{FungibleToken.Vault}] <- []
        if moetDebt > 0.0 {
            repaymentVaults.append(<- self.moetWithdrawRef.withdraw(amount: moetDebt))
        }

        // Close position: repay debt and withdraw all collateral in one call
        // Any overpayment will be returned along with collateral
        let returnedVaults <- self.position.closePosition(repaymentVaults: <-repaymentVaults)

        // Deposit all returned collateral and overpayment to appropriate vaults
        while returnedVaults.length > 0 {
            let vault <- returnedVaults.removeFirst()
            let vaultType = vault.getType()

            // Route to appropriate receiver based on token type
            if vaultType == Type<@FlowToken.Vault>() {
                self.flowReceiverRef.deposit(from: <-vault)
            } else if vaultType == Type<@MOET.Vault>() {
                self.moetReceiverRef.deposit(from: <-vault)
            } else {
                panic("Unexpected vault type returned: \(vaultType.identifier)")
            }
        }
        destroy returnedVaults
    }
} 
