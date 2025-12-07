import "FungibleToken"
import "DeFiActions"
import "DeFiActionsUtils"
import "FlowCreditMarket"
import "MOET"
import "DummyConnectors"

transaction {
    prepare(admin: auth(BorrowValue, IssueStorageCapabilityController) &Account) {
        // Issue a storage cap WITH the EParticipant entitlement
        let cap = admin.capabilities.storage.issue<
            auth(FlowCreditMarket.EParticipant) &FlowCreditMarket.Pool
        >(FlowCreditMarket.PoolStoragePath)

        let pool = cap.borrow() ?? panic("borrow failed")

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
