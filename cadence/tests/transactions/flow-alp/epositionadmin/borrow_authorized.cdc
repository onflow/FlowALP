import "FlowALPv0"
import "FlowALPModels"

/// TEST TRANSACTION — DO NOT USE IN PRODUCTION
///
/// Verifies that auth(EPositionAdmin) &PositionManager grants access to
/// PositionManager.borrowAuthorizedPosition, which returns an authorized
/// auth(EPositionAdmin) &Position reference.
///
/// @param pid: The position ID to borrow an authorized reference for
transaction(pid: UInt64) {
    let posRef: auth(FlowALPModels.EPositionAdmin) &FlowALPv0.Position

    prepare(signer: auth(BorrowValue) &Account) {
        let manager = signer.storage.borrow<auth(FlowALPModels.EPositionAdmin) &FlowALPv0.PositionManager>(
            from: FlowALPv0.PositionStoragePath
        ) ?? panic("Could not borrow PositionManager with EPositionAdmin entitlement")

        self.posRef = manager.borrowAuthorizedPosition(pid: pid)
    }

    execute {
        assert(self.posRef.id == pid, message: "Borrowed position ID does not match requested pid")
    }
}
