import "FlowALPv0"
import "FlowALPModels"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Verifies that auth(EPositionAdmin) &Position grants access to Position.provideSource.
/// Borrows the PositionManager with EPositionAdmin, gets an authorized Position reference,
/// and clears the top-up source (nil is always a valid argument).
///
/// @param pid: The position ID whose top-up source should be configured
transaction(pid: UInt64) {
    let position: auth(FlowALPModels.EPositionAdmin) &FlowALPv0.Position

    prepare(signer: auth(BorrowValue) &Account) {
        let manager = signer.storage.borrow<auth(FlowALPModels.EPositionAdmin) &FlowALPv0.PositionManager>(
            from: FlowALPv0.PositionStoragePath
        ) ?? panic("Could not borrow PositionManager with EPositionAdmin entitlement")

        self.position = manager.borrowAuthorizedPosition(pid: pid)
    }

    execute {
        // Passing nil clears any existing top-up source — always a valid no-op
        self.position.provideSource(source: nil)
    }
}
