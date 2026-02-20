import "FungibleToken"
import "FlowALPv0"
import "FlowALPModels"

/// Sets the maximum health on a position.
transaction(
    positionId: UInt64,
    maxHealth: UFix64
) {
    let position: auth(FlowALPModels.EPositionAdmin) &FlowALPv0.Position

    prepare(signer: auth(BorrowValue) &Account) {
        let manager = signer.storage.borrow<auth(FungibleToken.Withdraw, FlowALPModels.EPositionAdmin) &FlowALPv0.PositionManager>(
                from: FlowALPv0.PositionStoragePath
            )
            ?? panic("Could not find PositionManager in signer's storage")

        self.position = manager.borrowAuthorizedPosition(pid: positionId)
    }

    execute {
        self.position.setMaxHealth(maxHealth: maxHealth)
    }
}
