import "FlowALPv0"
import "FlowALPModels"

/// TEST TRANSACTION — DO NOT USE IN PRODUCTION
///
/// Verifies that storage ownership of PositionManager grants EPositionAdmin access to
/// PositionManager.borrowAuthorizedPosition and Position.setMinHealth.
/// EPositionAdmin comes exclusively from owning the PositionManager in storage
/// and cannot be delegated as a capability.
///
/// @param pid:       Own position ID to configure
/// @param minHealth: Minimum health factor before auto-borrow is triggered
transaction(pid: UInt64, minHealth: UFix64) {
    let position: auth(FlowALPModels.EPositionAdmin) &FlowALPv0.Position

    prepare(signer: auth(BorrowValue) &Account) {
        let manager = signer.storage.borrow<auth(FlowALPModels.EPositionAdmin) &FlowALPv0.PositionManager>(
            from: FlowALPv0.PositionStoragePath
        ) ?? panic("Could not borrow PositionManager with EPositionAdmin entitlement")

        self.position = manager.borrowAuthorizedPosition(pid: pid)
    }

    execute {
        self.position.setMinHealth(minHealth: minHealth)
    }
}
