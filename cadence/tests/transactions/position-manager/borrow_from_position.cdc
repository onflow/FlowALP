import "FungibleToken"
import "FlowToken"
import "MOET"
import "FlowALPv0"
import "FlowALPModels"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Borrows (withdraws) the specified token type from the position.
/// This creates a debit balance if the position doesn't have sufficient credit balance.
///
transaction(
    positionId: UInt64,
    tokenTypeIdentifier: String,
    amount: UFix64
) {
    let position: auth(FungibleToken.Withdraw) &FlowALPv0.Position
    let tokenType: Type
    let receiverVault: &{FungibleToken.Receiver}

    prepare(signer: auth(BorrowValue, SaveValue, IssueStorageCapabilityController, PublishCapability, UnpublishCapability) &Account) {
        // Borrow the PositionManager from constant storage path
        let manager = signer.storage.borrow<auth(FungibleToken.Withdraw, FlowALPModels.EPositionAdmin) &FlowALPv0.PositionManager>(
                from: FlowALPv0.PositionStoragePath
            )
            ?? panic("Could not find PositionManager in signer's storage")

        // Borrow the position with withdraw entitlement
        self.position = manager.borrowAuthorizedPosition(pid: positionId)

        // Parse the token type
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier: \(tokenTypeIdentifier)")

        // Ensure signer has a FlowToken vault to receive borrowed tokens
        // (Most borrows in tests are FlowToken)
        if signer.storage.type(at: /storage/flowTokenVault) == nil {
            signer.storage.save(<-FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>()), to: /storage/flowTokenVault)
        }

        // Get receiver for the specific token type
        var receiverRef: &{FungibleToken.Receiver}? = nil
        if tokenTypeIdentifier == "A.0000000000000003.FlowToken.Vault" {
            // For FlowToken, use the standard path
            receiverRef = signer.storage.borrow<&{FungibleToken.Receiver}>(from: /storage/flowTokenVault)
        } else if tokenTypeIdentifier == "A.0000000000000007.MOET.Vault" {
            // For MOET, use the MOET vault path
            receiverRef = signer.storage.borrow<&{FungibleToken.Receiver}>(from: MOET.VaultStoragePath)
        }

        self.receiverVault = receiverRef ?? panic("Could not borrow vault receiver for token type: \(tokenTypeIdentifier). Ensure vault is set up.")
    }

    execute {
        // Withdraw (borrow) from the position directly
        let borrowedVault <- self.position.withdraw(type: self.tokenType, amount: amount)

        // Deposit the borrowed tokens to the signer's vault
        self.receiverVault.deposit(from: <-borrowedVault)
    }
}
