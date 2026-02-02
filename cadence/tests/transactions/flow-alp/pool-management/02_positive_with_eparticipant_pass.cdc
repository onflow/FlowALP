import "FungibleToken"
import "DeFiActions"
import "DeFiActionsUtils"
import "FlowALPv1"
import "MOET"
import "DummyConnectors"

transaction {
    prepare(admin: auth(BorrowValue, IssueStorageCapabilityController) &Account) {
        // Issue a storage cap WITH the EParticipant entitlement
        let cap = admin.capabilities.storage.issue<
            auth(FlowALPv1.EParticipant) &FlowALPv1.Pool
        >(FlowALPv1.PoolStoragePath)

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
