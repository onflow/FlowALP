import "DeFiActions"
import "FlowALPv0"
import "FlowALPModels"
import "DummyConnectors"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Verifies that auth(EPositionAdmin) &Position grants access to Position.provideSink.
/// Borrows the PositionManager with EPositionAdmin, gets an authorized Position reference,
/// and sets a DummySink as the draw-down sink (then clears it with nil).
///
/// @param pid: The position ID whose sink should be configured
transaction(pid: UInt64) {
    let position: auth(FlowALPModels.EPositionAdmin) &FlowALPv0.Position

    prepare(signer: auth(BorrowValue) &Account) {
        let manager = signer.storage.borrow<auth(FlowALPModels.EPositionAdmin) &FlowALPv0.PositionManager>(
            from: FlowALPv0.PositionStoragePath
        ) ?? panic("Could not borrow PositionManager with EPositionAdmin entitlement")

        self.position = manager.borrowAuthorizedPosition(pid: pid)
    }

    execute {
        // Set a sink (DummySink accepts MOET, which is the pool's default token)
        self.position.provideSink(sink: DummyConnectors.DummySink())
        // Clear it again to leave state clean
        self.position.provideSink(sink: nil)
    }
}
