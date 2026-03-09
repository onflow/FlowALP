import "FungibleToken"
import "FlowALPv0"
import "FlowALPModels"
import "DeFiActions"

/// Sets the top-up source on a position.
transaction(
    positionId: UInt64,
    source: {DeFiActions.Source}?
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
        self.position.provideSource(source: source)
    }
}
