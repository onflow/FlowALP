import "FungibleToken"
import "FlowALPv0"
import "FlowALPPositionResources"
import "FlowALPModels"

/// Sets the minimum health on a position.
transaction(
    positionId: UInt64,
    minHealth: UFix64
) {
    let position: auth(FlowALPModels.EPositionAdmin) &FlowALPPositionResources.Position

    prepare(signer: auth(BorrowValue) &Account) {
        let manager = signer.storage.borrow<auth(FungibleToken.Withdraw, FlowALPModels.EPositionAdmin) &FlowALPPositionResources.PositionManager>(
                from: FlowALPv0.PositionStoragePath
            )
            ?? panic("Could not find PositionManager in signer's storage")

        self.position = manager.borrowAuthorizedPosition(pid: positionId)
    }

    execute {
        self.position.setMinHealth(minHealth: minHealth)
    }
}
