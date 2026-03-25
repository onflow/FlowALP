import "FungibleToken"
import "FlowALPv0"
import "FlowALPPositionResources"
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
transaction {
    let pool: auth(FlowALPModels.EParticipant) &FlowALPv0.Pool
    let moetVault: auth(FungibleToken.Withdraw) &MOET.Vault
    let manager: auth(FlowALPModels.EPositionAdmin) &FlowALPPositionResources.PositionManager

    prepare(signer: auth(BorrowValue, Storage) &Account) {
        // Direct borrow since signer owns the pool
        self.pool = signer.storage.borrow<auth(FlowALPModels.EParticipant) &FlowALPv0.Pool>(from: FlowALPv0.PoolStoragePath)
            ?? panic("Could not borrow Pool with EParticipant entitlement")

        self.moetVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &MOET.Vault>(from: MOET.VaultStoragePath)
            ?? panic("Could not borrow MOET vault")

        self.manager = signer.storage.borrow<auth(FlowALPModels.EPositionAdmin) &FlowALPPositionResources.PositionManager>(
            from: FlowALPv0.PositionStoragePath
        ) ?? panic("Could not borrow PositionManager with EPositionAdmin entitlement")
    }

    execute {
        let funds <- self.moetVault.withdraw(amount: 1.0)
        let position <- self.pool.createPosition(
            funds: <-funds,
            issuanceSink: DummyConnectors.DummySink(),
            repaymentSource: nil,
            pushToDrawDownSink: false
        )
        let newPid = position.id

        // Test addPosition (requires EPositionAdmin on PositionManager)
        self.manager.addPosition(position: <-position)

        // Test removePosition (requires EPositionAdmin on PositionManager)
        let removed <- self.manager.removePosition(pid: newPid)

        // Verify correctness and clean up
        assert(removed.id == newPid, message: "Removed position ID does not match created position ID")
        destroy removed
    }
}
