import "FungibleToken"
import "DeFiActions"
import "DeFiActionsUtils"
import "FlowCreditMarket"
import "MOET"
import "DummyConnectors"

transaction {
    prepare(admin: auth(BorrowValue, Storage, Capabilities) &Account) {
        let pool = admin.storage.borrow<auth(FlowCreditMarket.EParticipant, FlowCreditMarket.EPosition) &FlowCreditMarket.Pool>(from: FlowCreditMarket.PoolStoragePath)

        // Ensure PositionManager exists
        if admin.storage.borrow<&FlowCreditMarket.PositionManager>(from: FlowCreditMarket.PositionStoragePath) == nil {
            let manager <- FlowCreditMarket.createPositionManager()
            admin.storage.save(<-manager, to: FlowCreditMarket.PositionStoragePath)
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
        let manager = admin.storage.borrow<&FlowCreditMarket.PositionManager>(from: FlowCreditMarket.PositionStoragePath)!
        manager.addPosition(position: <-position)

        // Also allowed with EParticipant:
        let zero2 <- DeFiActionsUtils.getEmptyVault(Type<@MOET.Vault>())
        pool.depositToPosition(pid: pid, from: <- zero2)
    }
}
