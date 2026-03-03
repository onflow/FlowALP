// Repay debt and close position using Sources (supports swapping, multi-vault, etc.)
//
// This transaction uses the closePosition method with Source abstraction:
// 1. Creates a VaultSource from the user's MOET vault capability
// 2. closePosition pulls exactly what it needs from the source
// 3. Returns all collateral + any overpayment
//
// Benefits:
// - No debt precalculation needed in transaction
// - No buffer required
// - Supports swapping (can use SwapSource instead of VaultSource)
// - Contract handles all precision internally

import "FungibleToken"
import "FlowToken"
import "DeFiActions"
import "FungibleTokenConnectors"
import "FlowALPv0"
import "MOET"

transaction(positionId: UInt64) {

    let position: auth(FungibleToken.Withdraw) &FlowALPv0.Position
    let flowReceiverRef: &{FungibleToken.Receiver}
    let moetReceiverRef: &{FungibleToken.Receiver}
    let moetVaultCap: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>

    prepare(borrower: auth(BorrowValue, Capabilities) &Account) {
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

        // Get or create capability for MOET vault
        self.moetVaultCap = borrower.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(
            MOET.VaultStoragePath
        )
        assert(self.moetVaultCap.check(), message: "Invalid MOET vault capability")
    }

    execute {
        // Create a VaultSource from the MOET vault capability
        // closePosition will pull exactly what it needs
        let moetSource = FungibleTokenConnectors.VaultSource(
            min: nil,  // No minimum balance requirement
            withdrawVault: self.moetVaultCap,
            uniqueID: nil
        )

        // Close position with sources
        // Contract calculates debt internally and pulls exact amount needed
        let returnedVaults <- self.position.closePosition(repaymentSources: [moetSource])

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
