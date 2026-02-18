import "FungibleToken"
import "FlowToken"
import "FlowALPv1"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Borrows (withdraws) the specified token type from the position.
/// This creates a debit balance if the position doesn't have sufficient credit balance.
///
transaction(
    positionId: UInt64,
    tokenTypeIdentifier: String,
    tokenVaultStoragePath: StoragePath,
    amount: UFix64
) {
    let position: auth(FungibleToken.Withdraw) &FlowALPv1.Position
    let tokenType: Type
    let receiverVault: &{FungibleToken.Receiver}

    prepare(signer: auth(BorrowValue, SaveValue, IssueStorageCapabilityController, PublishCapability, UnpublishCapability) &Account) {
        // Borrow the PositionManager from constant storage path
        let manager = signer.storage.borrow<auth(FungibleToken.Withdraw, FlowALPv1.EPositionAdmin) &FlowALPv1.PositionManager>(
                from: FlowALPv1.PositionStoragePath
            )
            ?? panic("Could not find PositionManager in signer's storage")

        // Borrow the position with withdraw entitlement
        self.position = manager.borrowAuthorizedPosition(pid: positionId)

        // Parse the token type
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier: \(tokenTypeIdentifier)")
        
        self.receiverVault = signer.storage.borrow<&{FungibleToken.Receiver}>(from: tokenVaultStoragePath)
            ?? panic("Could not borrow receiver vault")
    }

    execute {
        // Withdraw (borrow) from the position directly
        let borrowedVault <- self.position.withdraw(type: self.tokenType, amount: amount)

        // Deposit the borrowed tokens to the signer's vault
        self.receiverVault.deposit(from: <-borrowedVault)
    }
}
