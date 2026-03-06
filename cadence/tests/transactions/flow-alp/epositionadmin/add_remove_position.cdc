import "FungibleToken"
import "FlowALPv0"
import "FlowALPModels"
import "MOET"
import "DummyConnectors"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Verifies that auth(EPositionAdmin) &PositionManager grants access to:
///   - PositionManager.addPosition
///   - PositionManager.removePosition
///
/// Creates a fresh position, adds it to the PositionManager, removes it, and destroys it.
/// This confirms both operations are accessible when the PositionManager is borrowed
/// with the EPositionAdmin entitlement.
///
/// NOTE: All logic is in prepare because @Position resources cannot be stored as
/// transaction fields, and execute has no storage access. The prepare-only pattern
/// is correct by necessity for resource-creating/moving transactions.
transaction {
    prepare(signer: auth(BorrowValue, Storage) &Account) {
        // Create a fresh position (direct borrow since signer owns the pool)
        let pool = signer.storage.borrow<auth(FlowALPModels.EParticipant) &FlowALPv0.Pool>(from: FlowALPv0.PoolStoragePath)
            ?? panic("Could not borrow Pool with EParticipant entitlement")

        let moetVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &MOET.Vault>(from: MOET.VaultStoragePath)
            ?? panic("Could not borrow MOET vault")
        let funds <- moetVault.withdraw(amount: 1.0)
        let position <- pool.createPosition(
            funds: <-funds,
            issuanceSink: DummyConnectors.DummySink(),
            repaymentSource: nil,
            pushToDrawDownSink: false
        )
        let newPid = position.id

        // Get PositionManager with EPositionAdmin entitlement
        let manager = signer.storage.borrow<auth(FlowALPModels.EPositionAdmin) &FlowALPv0.PositionManager>(
            from: FlowALPv0.PositionStoragePath
        ) ?? panic("Could not borrow PositionManager with EPositionAdmin entitlement")

        // Test addPosition (requires EPositionAdmin on PositionManager)
        manager.addPosition(position: <-position)

        // Test removePosition (requires EPositionAdmin on PositionManager)
        let removed <- manager.removePosition(pid: newPid)

        // Verify correctness and clean up
        assert(removed.id == newPid, message: "Removed position ID does not match created position ID")
        destroy removed
    }
}
