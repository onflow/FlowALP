import "FlowALPv0"
import "FlowALPPositionResources"
import "FlowALPModels"

/// Clears the top-up source for a position (sets it to nil) via EPositionAdmin on the PositionManager.
///
/// @param pid: The position ID whose top-up source should be configured
transaction(pid: UInt64) {
    let position: auth(FlowALPModels.EPositionAdmin) &FlowALPPositionResources.Position

    prepare(signer: auth(BorrowValue) &Account) {
        let manager = signer.storage.borrow<auth(FlowALPModels.EPositionAdmin) &FlowALPPositionResources.PositionManager>(
            from: FlowALPv0.PositionStoragePath
        ) ?? panic("Could not borrow PositionManager with EPositionAdmin entitlement")

        self.position = manager.borrowAuthorizedPosition(pid: pid)
    }

    execute {
        // Passing nil clears any existing top-up source — always a valid no-op
        self.position.provideSource(source: nil)
    }
}
