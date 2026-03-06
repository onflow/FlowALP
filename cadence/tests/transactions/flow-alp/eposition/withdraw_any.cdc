import "FungibleToken"
import "FlowALPv0"
import "FlowALPModels"
import "MOET"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Verifies that Capability<auth(EPosition) &Pool> grants:
///   Pool.withdraw — on a position owned by ANOTHER user
///
/// EPosition allows pool-level position operations on any position by ID,
/// regardless of which account owns that position. No EParticipant required.
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
        let vault <- self.pool.withdraw(pid: pid, amount: amount, type: Type<@MOET.Vault>())
        self.receiver.deposit(from: <-vault)
    }
}
