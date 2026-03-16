import "FungibleToken"
import "FlowALPv0"
import "FlowALPModels"
import "MOET"

/// Withdraws and pulls MOET from any position via an EPosition capability at PoolCapStoragePath.
/// EPosition allows operations on any position by ID, regardless of ownership.
///
/// @param pid:    Target position ID (owned by a different account)
/// @param amount: Amount to withdraw
transaction(pid: UInt64, amount: UFix64) {
    let pool: auth(FlowALPModels.EPosition) &FlowALPv0.Pool
    let receiver: &{FungibleToken.Receiver}

    prepare(signer: auth(BorrowValue) &Account) {
        let cap = signer.storage.borrow<&Capability<auth(FlowALPModels.EPosition) &FlowALPv0.Pool>>(
            from: FlowALPv0.PoolCapStoragePath
        ) ?? panic("EPosition capability not found")
        self.pool = cap.borrow() ?? panic("Could not borrow Pool with EPosition")
        self.receiver = signer.storage.borrow<&{FungibleToken.Receiver}>(from: MOET.VaultStoragePath)
            ?? panic("No MOET vault receiver")
    }

    execute {
        let vault <- self.pool.withdrawAndPull(
            pid: pid,
            type: Type<@MOET.Vault>(),
            amount: amount,
            pullFromTopUpSource: false
        )
        self.receiver.deposit(from: <-vault)
    }
}
