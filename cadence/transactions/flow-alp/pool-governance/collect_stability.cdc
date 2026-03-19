import "FlowALPv0"
import "FlowALPModels"

/// Manually triggers stability collection for a specific token type.
/// This withdraws accrued stability from reserves and deposits the result into the pool's stability fund.
///
/// Only governance-authorized accounts can execute this transaction.
///
/// Prerequisites:
/// - Token must have debit balance (totalDebitBalance > 0)
/// - Reserves must have available balance
/// - Time must have elapsed since last collection
///
/// @param tokenTypeIdentifier: The fully qualified type identifier of the token (e.g., "A.0x1.FlowToken.Vault")
transaction(tokenTypeIdentifier: String) {
    let pool: auth(FlowALPModels.EGovernance) &FlowALPv0.Pool
    let tokenType: Type

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALPModels.EGovernance) &FlowALPv0.Pool>(
            from: FlowALPv0.PoolStoragePath
        ) ?? panic("Could not borrow Pool at \(FlowALPv0.PoolStoragePath)")

        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier: \(tokenTypeIdentifier)")
    }

    execute {
        self.pool.collectStability(tokenType: self.tokenType)
    }
}
