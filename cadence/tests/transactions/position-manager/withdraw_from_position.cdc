import "FungibleToken"
import "FlowToken"
import "MOET"
import "DummyToken"
import "FlowALPv0"
import "FlowALPModels"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Withdraws the specified amount and token type from the position.
/// This will fail if the withdrawal would leave the position below the minimum balance requirement
/// (unless withdrawing all funds to close the position).
///
transaction(
    positionId: UInt64,
    tokenTypeIdentifier: String,
    amount: UFix64,
    pullFromTopUpSource: Bool
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

        // Ensure signer has a FlowToken vault to receive withdrawn tokens
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
        } else if tokenTypeIdentifier == "A.0000000000000007.DummyToken.Vault" {
            // For DummyToken, use the DummyToken vault path
            receiverRef = signer.storage.borrow<&{FungibleToken.Receiver}>(from: DummyToken.VaultStoragePath)
        }

        self.receiverVault = receiverRef ?? panic("Could not borrow vault receiver for token type: \(tokenTypeIdentifier). Ensure vault is set up.")
    }

    execute {
        // Withdraw from the position with optional top-up pulling
        let withdrawnVault <- self.position.withdrawAndPull(
            type: self.tokenType,
            amount: amount,
            pullFromTopUpSource: pullFromTopUpSource
        )

        // Deposit the withdrawn tokens to the signer's vault
        self.receiverVault.deposit(from: <-withdrawnVault)
    }
}
