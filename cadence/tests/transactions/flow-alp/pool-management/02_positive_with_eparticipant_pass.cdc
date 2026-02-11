import "FungibleToken"
import "DeFiActions"
import "DeFiActionsUtils"
import "FlowALPv1"
import "MOET"
import "DummyConnectors"

transaction {
    prepare(admin: auth(BorrowValue, IssueStorageCapabilityController) &Account) {
        let minter = admin.storage.borrow<&MOET.Minter>(from: MOET.AdminStoragePath)
            ?? panic("Could not borrow reference to MOET Minter from signer's account at path \(MOET.AdminStoragePath)")

        // Issue a storage cap WITH the EParticipant entitlement
        let cap = admin.capabilities.storage.issue<
            auth(FlowALPv1.EParticipant) &FlowALPv1.Pool
        >(FlowALPv1.PoolStoragePath)

        let pool = cap.borrow() ?? panic("borrow failed")

        // Call EParticipant-gated methods
        let initialFunds <- minter.mintTokens(amount: 1.0)
        let position <- pool.createPosition(
            funds: <- initialFunds,
            issuanceSink: DummyConnectors.DummySink(),
            repaymentSource: nil,
            pushToDrawDownSink: false
        )
        let pid = position.id
        destroy position

        // Also allowed with EParticipant:
        let additionalFunds <- minter.mintTokens(amount: 1.0)
        pool.depositToPosition(pid: pid, from: <- additionalFunds)
    }
}
