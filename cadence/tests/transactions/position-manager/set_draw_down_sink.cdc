import "FlowALPv0"
import "FlowALPPositionResources"
import "FlowALPModels"
import "DeFiActions"
/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Sets the draw-down sink.
/// If nil, the Pool will not push overflown value.
/// If a non-nil value is provided, the Sink MUST accept MOET deposits or the operation will revert.
///
transaction(
    positionId: UInt64,
    sink: {DeFiActions.Sink}?
) {
    let position: auth(FlowALPModels.EPositionAdmin) &FlowALPPositionResources.Position

    prepare(signer: auth(BorrowValue, SaveValue) &Account) {
        // Borrow the PositionManager from constant storage path
        let manager = signer.storage.borrow<auth(FlowALPModels.EPositionAdmin) &FlowALPPositionResources.PositionManager>(
                from: FlowALPv0.PositionStoragePath
            )
            ?? panic("Could not find PositionManager in signer's storage")

        // Borrow the position with EPositionAdmin entitlement
        self.position = manager.borrowAuthorizedPosition(pid: positionId)
    }

    execute {
        // Provide new sink for the position directly
        self.position.provideSink(sink: sink)
    }
}
