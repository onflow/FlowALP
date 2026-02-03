import "FlowCreditMarket"
import "FungibleToken"
import "MockFlowCreditMarketConsumer"

/// Withdraw assets from an existing credit position, depositing to signer's Receiver
transaction(
    positionID: UInt64,
    tokenTypeIdentifier: String,
    amount: UFix64,
    pullFromTopUpSource: Bool
) {
    let tokenType: Type
    let pool: auth(FlowCreditMarket.EParticipant, FlowCreditMarket.EPosition) &FlowCreditMarket.Pool
    let receiverRef: &{FungibleToken.Receiver}

    prepare(signer: auth(Storage, Capabilities, BorrowValue) &Account) {
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier: ".concat(tokenTypeIdentifier))

        // Borrow Pool with the entitlements required by withdrawAndPull
        let poolCapability = MockFlowCreditMarketConsumer.getPoolCapability()
        self.pool = poolCapability.borrow()!
        // Get capability (NOT optional), then borrow a reference (optional)
        let cap = signer.capabilities.get<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
        self.receiverRef = cap.borrow()
            ?? panic("Could not borrow receiver ref from /public/flowTokenReceiver")
    }

    execute {
        let withdrawn <- self.pool.withdrawAndPull(
            pid: positionID,
            type: self.tokenType,
            amount: amount,
            pullFromTopUpSource: pullFromTopUpSource
        )

        self.receiverRef.deposit(from: <-withdrawn)
    }
}
