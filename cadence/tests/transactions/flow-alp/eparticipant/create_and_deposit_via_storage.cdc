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
///
/// NOTE: All logic is in prepare because @Position resources cannot be stored as
/// transaction fields, and execute has no storage access. The prepare-only pattern
/// is correct by necessity for resource-creating transactions.
transaction {
    prepare(admin: auth(BorrowValue, IssueStorageCapabilityController) &Account) {
        let minter = admin.storage.borrow<&MOET.Minter>(from: MOET.AdminStoragePath)
            ?? panic("Could not borrow reference to MOET Minter from signer's account at path \(MOET.AdminStoragePath)")

        // Issue a storage cap WITH the EParticipant entitlement
        let cap = admin.capabilities.storage.issue<
            auth(FlowALPModels.EParticipant) &FlowALPv0.Pool
        >(FlowALPv0.PoolStoragePath)

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
