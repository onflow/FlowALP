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
transaction {
    let pool: auth(FlowALPModels.EParticipant, FlowALPModels.EPosition) &FlowALPv0.Pool
    let moetVault: auth(FungibleToken.Withdraw) &MOET.Vault
    let manager: auth(FlowALPModels.EPositionAdmin) &FlowALPv0.PositionManager

    prepare(admin: auth(BorrowValue, Storage) &Account) {
        self.pool = admin.storage.borrow<auth(FlowALPModels.EParticipant, FlowALPModels.EPosition) &FlowALPv0.Pool>(from: FlowALPv0.PoolStoragePath)
            ?? panic("Could not borrow Pool with EParticipant+EPosition entitlement")

        self.moetVault = admin.storage.borrow<auth(FungibleToken.Withdraw) &MOET.Vault>(from: MOET.VaultStoragePath)
            ?? panic("Could not borrow MOET vault")

        // Ensure PositionManager exists
        if admin.storage.borrow<&FlowALPv0.PositionManager>(from: FlowALPv0.PositionStoragePath) == nil {
            let manager <- FlowALPv0.createPositionManager()
            admin.storage.save(<-manager, to: FlowALPv0.PositionStoragePath)
        }
        self.manager = admin.storage.borrow<auth(FlowALPModels.EPositionAdmin) &FlowALPv0.PositionManager>(from: FlowALPv0.PositionStoragePath)!
    }

    execute {
        // Pool.createPosition — requires EParticipant
        let funds <- self.moetVault.withdraw(amount: 1.0)
        let position <- self.pool.createPosition(
            funds: <-funds,
            issuanceSink: DummyConnectors.DummySink(),
            repaymentSource: nil,
            pushToDrawDownSink: false
        )
        let pid = position.id

        // Add position to manager
        self.manager.addPosition(position: <-position)

        // Pool.depositToPosition — requires EParticipant
        let moreFunds <- self.moetVault.withdraw(amount: 1.0)
        self.pool.depositToPosition(pid: pid, from: <-moreFunds)
    }
}
