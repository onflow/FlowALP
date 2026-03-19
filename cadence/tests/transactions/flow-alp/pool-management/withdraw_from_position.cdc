import "FlowALPv0"
import "FlowALPPositionResources"
import "FlowALPModels"
import "FungibleToken"

/// Withdraw assets from an existing credit position, depositing to signer's Receiver
transaction(
    positionID: UInt64,
    tokenTypeIdentifier: String,
    amount: UFix64,
    pullFromTopUpSource: Bool
) {
    let tokenType: Type
    let receiverRef: &{FungibleToken.Receiver}
    let positionManager: auth(FlowALPModels.EPositionAdmin) &FlowALPPositionResources.PositionManager

    prepare(signer: auth(Storage, Capabilities, BorrowValue) &Account) {
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier: ".concat(tokenTypeIdentifier))

        self.positionManager = signer.storage.borrow<auth(FlowALPModels.EPositionAdmin) &FlowALPPositionResources.PositionManager>(from: FlowALPv0.PositionStoragePath)
            ?? panic("PositionManager not found")

        // Get capability (NOT optional), then borrow a reference (optional)
        let cap = signer.capabilities.get<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
        self.receiverRef = cap.borrow()
            ?? panic("Could not borrow receiver ref from /public/flowTokenReceiver")
    }

    execute {
        let position = self.positionManager.borrowAuthorizedPosition(positionID)
            ?? panic("Could not borrow authorized position")
        let withdrawn <- self.pool.withdrawAndPull(
            type: self.tokenType,
            amount: amount,
            pullFromTopUpSource: pullFromTopUpSource
        )

        self.receiverRef.deposit(from: <-withdrawn)
    }
}
