import "FungibleToken"
import "FlowALPv0"
import "FlowALPModels"
import "MOET"
import "DummyConnectors"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Verifies that Capability<auth(EParticipant) &Pool> (EParticipant-ONLY, fixed beta cap) grants:
///   Pool.createPosition
///   Pool.depositToPosition
///
/// Uses the cap stored at FlowALPv0.PoolCapStoragePath.
transaction {
    let pool: auth(FlowALPModels.EParticipant) &FlowALPv0.Pool
    let vault: auth(FungibleToken.Withdraw) &MOET.Vault
    let manager: auth(FlowALPModels.EPositionAdmin) &FlowALPv0.PositionManager

    prepare(signer: auth(BorrowValue, Storage) &Account) {
        let cap = signer.storage.borrow<&Capability<auth(FlowALPModels.EParticipant) &FlowALPv0.Pool>>(
            from: FlowALPv0.PoolCapStoragePath
        ) ?? panic("EParticipant-only capability not found")

        self.pool = cap.borrow() ?? panic("Could not borrow Pool with EParticipant")

        self.vault = signer.storage.borrow<auth(FungibleToken.Withdraw) &MOET.Vault>(from: MOET.VaultStoragePath)
            ?? panic("No MOET vault")

        // Ensure PositionManager exists
        if signer.storage.borrow<&FlowALPv0.PositionManager>(from: FlowALPv0.PositionStoragePath) == nil {
            let manager <- FlowALPv0.createPositionManager()
            signer.storage.save(<-manager, to: FlowALPv0.PositionStoragePath)
        }
        self.manager = signer.storage.borrow<auth(FlowALPModels.EPositionAdmin) &FlowALPv0.PositionManager>(
            from: FlowALPv0.PositionStoragePath
        ) ?? panic("No PositionManager")
    }

    execute {
        let funds <- self.vault.withdraw(amount: 5.0)

        // createPosition — requires EParticipant
        let position <- self.pool.createPosition(
            funds: <-funds,
            issuanceSink: DummyConnectors.DummySink(),
            repaymentSource: nil,
            pushToDrawDownSink: false
        )
        let pid = position.id
        self.manager.addPosition(position: <-position)

        // depositToPosition — requires EParticipant
        let moreFunds <- self.vault.withdraw(amount: 1.0)
        self.pool.depositToPosition(pid: pid, from: <-moreFunds)
    }
}
