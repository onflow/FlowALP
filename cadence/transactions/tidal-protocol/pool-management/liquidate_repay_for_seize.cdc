import "FungibleToken"
import "FlowToken"

import "TidalProtocol"
import "MOET"

/// Liquidate a position by repaying exactly the required amount to reach target HF and seizing collateral
/// debtVaultIdentifier: e.g., Type<@MOET.Vault>().identifier
/// seizeVaultIdentifier: e.g., Type<@FlowToken.Vault>().identifier
transaction(pid: UInt64, debtVaultIdentifier: String, seizeVaultIdentifier: String, minSeizeAmount: UFix64) {
    let pool: &TidalProtocol.Pool
    let receiver: &{FungibleToken.Receiver}

    prepare(signer: auth(BorrowValue) &Account) {
        let protocolAddress = Type<@TidalProtocol.Pool>().address!
        self.pool = getAccount(protocolAddress).capabilities.borrow<&TidalProtocol.Pool>(TidalProtocol.PoolPublicPath)
            ?? panic("Could not borrow Pool at \(TidalProtocol.PoolPublicPath)")

        // Receiver for seized collateral (assumes Flow in example; resolve dynamically below)
        self.receiver = signer.capabilities.borrow<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
            ?? panic("Could not borrow receiver reference for seized Vault")
    }

    execute {
        let debtType = CompositeType(debtVaultIdentifier) ?? panic("Invalid debtVaultIdentifier: \(debtVaultIdentifier)")
        let seizeType = CompositeType(seizeVaultIdentifier) ?? panic("Invalid seizeVaultIdentifier: \(seizeVaultIdentifier)")

        // Quote required repay and seize amounts
        let quote = self.pool.quoteLiquidation(pid: pid, debtType: debtType, seizeType: seizeType)
        assert(quote.requiredRepay > 0.0, message: "Nothing to liquidate")
        assert(quote.seizeAmount >= minSeizeAmount, message: "Seize below minimum")

        // Withdraw exact repay from signer's MOET (or other debt token) vault
        let repayFrom = getAuthAccount(getAccount(Type<@MOET.Vault>().address!).address)
        let repayVaultRef = repayFrom.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: MOET.VaultStoragePath)
            ?? panic("No debt token vault in storage")
        let repay <- repayVaultRef.withdraw(amount: quote.requiredRepay)

        // Execute liquidation; get seized collateral vault
        let seized <- self.pool.liquidateRepayForSeize(
            pid: pid,
            debtType: debtType,
            maxRepayAmount: quote.requiredRepay,
            seizeType: seizeType,
            minSeizeAmount: minSeizeAmount,
            from: <-repay
        )

        // Deposit seized assets to signer's receiver
        self.receiver.deposit(from: <-seized)
    }
}
