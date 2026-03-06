import "FungibleToken"
import "FlowALPv0"
import "FlowALPModels"
import "MOET"
import "DummyConnectors"

/// TEST TRANSACTION — DO NOT USE IN PRODUCTION
///
/// Verifies that a Pool borrow with auth(EParticipant, EPosition) allows
/// Pool.createPosition and Pool.depositToPosition, creating a PositionManager
/// if one does not already exist. Used after the publish→claim beta cap flow.
///
/// NOTE: All logic is in prepare because @Position resources cannot be stored as
/// transaction fields, and execute has no storage access. The prepare-only pattern
/// is correct by necessity for resource-creating transactions.
transaction {
    prepare(admin: auth(BorrowValue, Storage) &Account) {
        let pool = admin.storage.borrow<auth(FlowALPModels.EParticipant, FlowALPModels.EPosition) &FlowALPv0.Pool>(from: FlowALPv0.PoolStoragePath)
            ?? panic("Could not borrow Pool with EParticipant+EPosition entitlement")

        let moetVault = admin.storage.borrow<auth(FungibleToken.Withdraw) &MOET.Vault>(from: MOET.VaultStoragePath)
            ?? panic("Could not borrow MOET vault")

        // Ensure PositionManager exists
        if admin.storage.borrow<&FlowALPv0.PositionManager>(from: FlowALPv0.PositionStoragePath) == nil {
            let manager <- FlowALPv0.createPositionManager()
            admin.storage.save(<-manager, to: FlowALPv0.PositionStoragePath)
        }

        // Pool.createPosition — requires EParticipant
        let funds <- moetVault.withdraw(amount: 1.0)
        let position <- pool.createPosition(
            funds: <-funds,
            issuanceSink: DummyConnectors.DummySink(),
            repaymentSource: nil,
            pushToDrawDownSink: false
        )

        let pid = position.id

        // Add position to manager
        let manager = admin.storage.borrow<auth(FlowALPModels.EPositionAdmin) &FlowALPv0.PositionManager>(from: FlowALPv0.PositionStoragePath)!
        manager.addPosition(position: <-position)

        // Pool.depositToPosition — requires EParticipant
        let moreFunds <- moetVault.withdraw(amount: 1.0)
        pool.depositToPosition(pid: pid, from: <-moreFunds)
    }
}
