import "FungibleToken"
import "DeFiActions"
import "DeFiActionsUtils"
import "FlowALPv0"
import "MOET"
import "DummyConnectors"

transaction {
    prepare(admin: auth(BorrowValue, Storage, Capabilities) &Account) {
        let pool = admin.storage.borrow<auth(FlowALPv0.EParticipant) &FlowALPv0.Pool>(from: FlowALPv0.PoolStoragePath)

        // Ensure PositionManager exists
        if admin.storage.borrow<&FlowALPv0.PositionManager>(from: FlowALPv0.PositionStoragePath) == nil {
            let manager <- FlowALPv0.createPositionManager()
            admin.storage.save(<-manager, to: FlowALPv0.PositionStoragePath)
        }

        // Call EParticipant-gated methods
        let zero1 <- DeFiActionsUtils.getEmptyVault(Type<@MOET.Vault>())
        let position <- pool.createPosition(
            funds: <- zero1,
            issuanceSink: DummyConnectors.DummySink(),
            repaymentSource: nil,
            pushToDrawDownSink: false
        )

        let pid = position.id

        // Add position to manager
        let manager = admin.storage.borrow<&FlowALPv0.PositionManager>(from: FlowALPv0.PositionStoragePath)!
        manager.addPosition(position: <-position)

        // Also allowed with EParticipant:
        let zero2 <- DeFiActionsUtils.getEmptyVault(Type<@MOET.Vault>())
        pool.depositToPosition(pid: pid, from: <- zero2)
    }
}
