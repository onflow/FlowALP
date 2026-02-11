import "FungibleToken"
import "FlowALPv1"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Sets the minimum health on a position.
///
transaction(
    positionId: UInt64,
    minHealth: UFix64
) {
    let position: auth(FlowALPv1.EPositionAdmin) &FlowALPv1.Position

    prepare(signer: auth(BorrowValue) &Account) {
        let manager = signer.storage.borrow<auth(FungibleToken.Withdraw, FlowALPv1.EPositionAdmin) &FlowALPv1.PositionManager>(
                from: FlowALPv1.PositionStoragePath
            )
            ?? panic("Could not find PositionManager in signer's storage")

        self.position = manager.borrowAuthorizedPosition(pid: positionId)
    }

    execute {
        self.position.setMinHealth(minHealth: minHealth)
    }
}
