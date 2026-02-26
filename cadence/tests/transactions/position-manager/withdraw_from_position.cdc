import "FungibleToken"
import "FlowToken"
import "FlowALPv0"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Withdraws the specified amount and token type from the position.
/// This will fail if the withdrawal would leave the position below the minimum balance requirement
/// (unless withdrawing all funds to close the position).
///
transaction(
    positionId: UInt64,
    tokenTypeIdentifier: String,
    receiverVaultStoragePath: StoragePath,
    amount: UFix64,
    pullFromTopUpSource: Bool
) {
    let position: auth(FungibleToken.Withdraw) &FlowALPv0.Position
    let tokenType: Type
    let receiverVault: &{FungibleToken.Receiver}

    prepare(signer: auth(BorrowValue) &Account) {
        // Borrow the PositionManager from constant storage path
        let manager = signer.storage.borrow<auth(FungibleToken.Withdraw, FlowALPv0.EPositionAdmin) &FlowALPv0.PositionManager>(
            from: FlowALPv0.PositionStoragePath
        ) ?? panic("Could not find PositionManager in signer's storage")

        // Borrow the position with withdraw entitlement
        self.position = manager.borrowAuthorizedPosition(pid: positionId)

        // Parse the token type
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier: \(tokenTypeIdentifier)")

        self.receiverVault = signer.storage.borrow<&{FungibleToken.Receiver}>(from: receiverVaultStoragePath)
            ?? panic("Could not borrow receiver vault at \(receiverVaultStoragePath)")
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