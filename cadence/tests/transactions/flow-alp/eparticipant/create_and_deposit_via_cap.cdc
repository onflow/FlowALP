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
///
/// NOTE: All logic is in prepare because @Position resources cannot be stored as
/// transaction fields, and execute has no storage access. The prepare-only pattern
/// is correct by necessity for resource-creating transactions.
transaction {
    prepare(signer: auth(BorrowValue, Storage) &Account) {
        let cap = signer.storage.borrow<&Capability<auth(FlowALPModels.EParticipant) &FlowALPv0.Pool>>(
            from: FlowALPv0.PoolCapStoragePath
        ) ?? panic("EParticipant-only capability not found")

        let pool = cap.borrow() ?? panic("Could not borrow Pool with EParticipant")

        let vault = signer.storage.borrow<auth(FungibleToken.Withdraw) &MOET.Vault>(from: MOET.VaultStoragePath)
            ?? panic("No MOET vault")

        // Ensure PositionManager exists (plain borrow is sufficient for addPosition)
        if signer.storage.borrow<&FlowALPv0.PositionManager>(from: FlowALPv0.PositionStoragePath) == nil {
            let manager <- FlowALPv0.createPositionManager()
            signer.storage.save(<-manager, to: FlowALPv0.PositionStoragePath)
        }
        let manager = signer.storage.borrow<auth(FlowALPModels.EPositionAdmin) &FlowALPv0.PositionManager>(
            from: FlowALPv0.PositionStoragePath
        ) ?? panic("No PositionManager")

        let funds <- vault.withdraw(amount: 5.0)

        // createPosition — requires EParticipant
        let position <- pool.createPosition(
            funds: <-funds,
            issuanceSink: DummyConnectors.DummySink(),
            repaymentSource: nil,
            pushToDrawDownSink: false
        )
        let pid = position.id
        manager.addPosition(position: <-position)

        // depositToPosition — requires EParticipant
        let moreFunds <- vault.withdraw(amount: 1.0)
        pool.depositToPosition(pid: pid, from: <-moreFunds)
    }
}
