import "FungibleToken"
import "DeFiActions"
import "DeFiActionsUtils"
import "FlowCreditMarket"
import "MOET"
import "DummyConnectors"

/// Tries to call Pool.createPosition using a plain &Pool ref (no EParticipant).
/// This should fail at CHECKING with an access/entitlement error.
transaction {
    prepare(admin: auth(BorrowValue, IssueStorageCapabilityController) &Account) {
        // Issue a storage cap WITHOUT any entitlement
        let cap = admin.capabilities.storage.issue<&FlowCreditMarket.Pool>(
            FlowCreditMarket.PoolStoragePath
        )
        let pool = cap.borrow() ?? panic("nil pool")


        // EXPECTED: checker rejects this call (createPosition is access(EParticipant)).
        let zero <- DeFiActionsUtils.getEmptyVault(Type<@MOET.Vault>())
        let _ = pool.createPosition(
            funds: <- zero,
            issuanceSink: DummyConnectors.DummySink(),
            repaymentSource: nil,
            pushToDrawDownSink: false
        )
    }
}
