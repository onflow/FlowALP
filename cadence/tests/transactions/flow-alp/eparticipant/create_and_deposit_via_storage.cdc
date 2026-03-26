import "FungibleToken"
import "DeFiActions"
import "DeFiActionsUtils"
import "FlowALPv0"
import "FlowALPModels"
import "MOET"
import "DummyConnectors"

/// TEST TRANSACTION — DO NOT USE IN PRODUCTION
///
/// Verifies that auth(EParticipant) &Pool (issued inline as a storage capability) grants:
///   Pool.createPosition
///   Pool.depositToPosition
transaction {
    let pool: auth(FlowALPModels.EParticipant) &FlowALPv0.Pool
    let minter: &MOET.Minter

    prepare(admin: auth(BorrowValue, IssueStorageCapabilityController) &Account) {
        self.minter = admin.storage.borrow<&MOET.Minter>(from: MOET.AdminStoragePath)
            ?? panic("Could not borrow reference to MOET Minter from signer's account at path \(MOET.AdminStoragePath)")

        // Issue a storage cap WITH the EParticipant entitlement
        let cap = admin.capabilities.storage.issue<
            auth(FlowALPModels.EParticipant) &FlowALPv0.Pool
        >(FlowALPv0.PoolStoragePath)

        self.pool = cap.borrow() ?? panic("borrow failed")
    }

    execute {
        // Call EParticipant-gated methods
        let initialFunds <- self.minter.mintTokens(amount: 1.0)
        let position <- self.pool.createPosition(
            funds: <- initialFunds,
            issuanceSink: DummyConnectors.DummySink(),
            repaymentSource: nil,
            pushToDrawDownSink: false
        )
        let pid = position.id
        destroy position

        // Also allowed with EParticipant:
        let additionalFunds <- self.minter.mintTokens(amount: 1.0)
        self.pool.depositToPosition(pid: pid, from: <- additionalFunds)
    }
}
