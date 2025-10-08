import "FungibleToken"
import "FlowToken"

import "TidalProtocol"
import "MOET"

/// Liquidate a position by repaying exactly the required amount to reach target HF and seizing collateral
/// debtVaultIdentifier: e.g., Type<@MOET.Vault>().identifier
/// seizeVaultIdentifier: e.g., Type<@FlowToken.Vault>().identifier
transaction(pid: UInt64, debtVaultIdentifier: String, seizeVaultIdentifier: String, maxRepayAmount: UFix64, minSeizeAmount: UFix64) {
    let pool: &TidalProtocol.Pool
    let receiver: &{FungibleToken.Receiver}
    var refundReceiver: &{FungibleToken.Receiver}?
    let debtType: Type
    let seizeType: Type
    let repay: @{FungibleToken.Vault}

    prepare(signer: auth(BorrowValue, SaveValue, IssueStorageCapabilityController, PublishCapability, UnpublishCapability) &Account) {
        let protocolAddress = Type<@TidalProtocol.Pool>().address!
        self.pool = getAccount(protocolAddress).capabilities.borrow<&TidalProtocol.Pool>(TidalProtocol.PoolPublicPath)
            ?? panic("Could not borrow Pool at \(TidalProtocol.PoolPublicPath)")

        // Resolve types
        self.debtType = CompositeType(debtVaultIdentifier) ?? panic("Invalid debtVaultIdentifier: \(debtVaultIdentifier)")
        self.seizeType = CompositeType(seizeVaultIdentifier) ?? panic("Invalid seizeVaultIdentifier: \(seizeVaultIdentifier)")

        // Add refundReceiver setup
        self.refundReceiver = nil
        if self.debtType == Type<@MOET.Vault>() {
            self.refundReceiver = signer.capabilities.borrow<&{FungibleToken.Receiver}>(MOET.ReceiverPublicPath)
        } else if self.debtType == Type<@FlowToken.Vault>() {
            self.refundReceiver = signer.capabilities.borrow<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
        }
        assert(self.refundReceiver != nil, message: "Missing refund receiver for debt type")

        // Quote
        let quote = self.pool.quoteLiquidation(pid: pid, debtType: self.debtType, seizeType: self.seizeType)
        assert(quote.requiredRepay > 0.0, message: "Nothing to liquidate")
        assert(quote.seizeAmount >= minSeizeAmount, message: "Seize below minimum")
        assert(maxRepayAmount >= quote.requiredRepay, message: "Max repay too low")

        // Withdraw maxRepayAmount
        var tmpRepay: @{FungibleToken.Vault}? <- nil
        if self.debtType == Type<@MOET.Vault>() {
            let repayVaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: MOET.VaultStoragePath)
                ?? panic("No MOET vault in storage")
            assert(repayVaultRef.balance >= maxRepayAmount, message: "Insufficient MOET balance")
            tmpRepay <-! repayVaultRef.withdraw(amount: maxRepayAmount)
        }
        if tmpRepay == nil && self.debtType == Type<@FlowToken.Vault>() {
            let repayVaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: /storage/flowTokenVault)
                ?? panic("No Flow vault in storage")
            assert(repayVaultRef.balance >= maxRepayAmount, message: "Insufficient Flow balance")
            tmpRepay <-! repayVaultRef.withdraw(amount: maxRepayAmount)
        }
        assert(tmpRepay != nil, message: "Unsupported debt token type for demo transaction")
        self.repay <- tmpRepay!

        // Receiver for seized collateral (supports Flow or MOET in demo)
        let flowRecv = signer.capabilities.borrow<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
        let moetRecv = signer.capabilities.borrow<&{FungibleToken.Receiver}>(MOET.ReceiverPublicPath)
        assert(flowRecv != nil || moetRecv != nil, message: "Missing receiver for seized tokens")
        if flowRecv != nil {
            self.receiver = flowRecv!
        } else {
            self.receiver = moetRecv!
        }
    }

    execute {
        // Execute liquidation; get seized collateral vault
        let result <- self.pool.liquidateRepayForSeize(
            pid: pid,
            debtType: self.debtType,
            maxRepayAmount: maxRepayAmount,
            seizeType: self.seizeType,
            minSeizeAmount: minSeizeAmount,
            from: <-self.repay
        )
        let seized <- result.takeSeized()
        let remainder <- result.takeRemainder()
        destroy result

        self.receiver.deposit(from: <-seized)
        self.refundReceiver!.deposit(from: <-remainder)
    }
}
