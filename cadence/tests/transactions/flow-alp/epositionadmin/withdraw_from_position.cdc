import "FlowALPv0"
import "FlowALPPositionResources"
import "FlowALPModels"
import "FungibleToken"

/// Withdraw assets from an existing credit position, depositing to signer's Receiver
transaction(
    positionID: UInt64,
    tokenTypeIdentifier: String,
    receiverVaultStoragePath: StoragePath,
    amount: UFix64,
    pullFromTopUpSource: Bool
) {
    let tokenType: Type
    let receiverRef: &{FungibleToken.Receiver}
    let positionManager: auth(FlowALPModels.EPositionAdmin) &FlowALPPositionResources.PositionManager

    prepare(signer: auth(Storage, Capabilities, BorrowValue) &Account) {
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier: \(tokenTypeIdentifier)")

        self.positionManager = signer.storage.borrow<auth(FlowALPModels.EPositionAdmin) &FlowALPPositionResources.PositionManager>(from: FlowALPv0.PositionStoragePath)
            ?? panic("PositionManager not found")

        self.receiverRef = signer.storage.borrow<&{FungibleToken.Receiver}>(from: receiverVaultStoragePath)
            ?? panic("Could not borrow receiver vault at \(receiverVaultStoragePath)")
    }

    execute {
        let position = self.positionManager.borrowAuthorizedPosition(pid: positionID)
        let withdrawn <- position.withdrawAndPull(
            type: self.tokenType,
            amount: amount,
            pullFromTopUpSource: pullFromTopUpSource
        )

        self.receiverRef.deposit(from: <-withdrawn)
    }
}
