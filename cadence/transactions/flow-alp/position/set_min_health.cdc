import "FungibleToken"
import "FlowALPv0"

/// Sets the minimum health on a position.
transaction(
    positionId: UInt64,
    minHealth: UFix64
) {
    let position: auth(FlowALPv0.EPositionAdmin) &FlowALPv0.Position

    prepare(signer: auth(BorrowValue) &Account) {
        let manager = signer.storage.borrow<auth(FungibleToken.Withdraw, FlowALPv0.EPositionAdmin) &FlowALPv0.PositionManager>(
                from: FlowALPv0.PositionStoragePath
            )
            ?? panic("Could not find PositionManager in signer's storage")

        self.position = manager.borrowAuthorizedPosition(pid: positionId)
    }

    execute {
        self.position.setMinHealth(minHealth: minHealth)
    }
}
