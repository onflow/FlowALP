import "FungibleToken"
import "DeFiActions"
import "DeFiActionsUtils"
import "TidalProtocol"
import "MOET"
import "DummyConnectors"

transaction {
    prepare(admin: auth(BorrowValue) &Account) {
        let pool = admin.storage.borrow<auth(TidalProtocol.EParticipant, TidalProtocol.EPosition) &TidalProtocol.Pool>(from: TidalProtocol.PoolStoragePath)

        // Call EParticipant-gated methods
        let zero1 <- DeFiActionsUtils.getEmptyVault(Type<@MOET.Vault>())
        let pid = pool.createPosition(
            funds: <- zero1,
            issuanceSink: DummyConnectors.DummySink(),
            repaymentSource: nil,
            pushToDrawDownSink: false
        )

        // Also allowed with EParticipant:
        let zero2 <- DeFiActionsUtils.getEmptyVault(Type<@MOET.Vault>())
        pool.depositToPosition(pid: pid, from: <- zero2)
    }
}
