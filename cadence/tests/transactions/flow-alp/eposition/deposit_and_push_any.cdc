import "FungibleToken"
import "FlowALPv0"
import "FlowALPModels"
import "MOET"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Verifies that Capability<auth(EPosition) &Pool> grants:
///   Pool.depositAndPush — on a position owned by ANOTHER user
///
/// EPosition allows pool-level position operations on any position by ID,
/// regardless of which account owns that position. No EParticipant required.
///
/// @param pid:    Target position ID (owned by a different account)
/// @param amount: Amount of MOET to deposit
transaction(pid: UInt64, amount: UFix64) {
    let pool: auth(FlowALPModels.EPosition) &FlowALPv0.Pool
    let funds: @{FungibleToken.Vault}

    prepare(signer: auth(BorrowValue) &Account) {
        let cap = signer.storage.borrow<&Capability<auth(FlowALPModels.EPosition) &FlowALPv0.Pool>>(
            from: FlowALPv0.PoolCapStoragePath
        ) ?? panic("EPosition capability not found")
        self.pool = cap.borrow() ?? panic("Could not borrow Pool with EPosition")
        let vault = signer.storage.borrow<auth(FungibleToken.Withdraw) &MOET.Vault>(from: MOET.VaultStoragePath)
            ?? panic("Could not borrow MOET vault with Withdraw entitlement")
        self.funds <- vault.withdraw(amount: amount)
    }

    execute {
        self.pool.depositAndPush(pid: pid, from: <-self.funds, pushToDrawDownSink: false)
    }
}
