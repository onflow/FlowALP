import "FlowALPv1"

/// Manually triggers insurance collection for a specific token type.
/// This withdraws accrued insurance from reserves, swaps to MOET via the configured swapper,
/// and deposits the result into the pool's insurance fund.
///
/// Parameters:
/// - tokenTypeIdentifier: String identifier of the token type (e.g., "A.0x07.MOET.Vault")
transaction(tokenTypeIdentifier: String) {
    let pool: auth(FlowALPv1.EGovernance) &FlowALPv1.Pool
    let tokenType: Type

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALPv1.EGovernance) &FlowALPv1.Pool>(
            from: FlowALPv1.PoolStoragePath
        ) ?? panic("Could not borrow Pool at \(FlowALPv1.PoolStoragePath)")

        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier: \(tokenTypeIdentifier)")
    }

    execute {
        self.pool.collectInsurance(tokenType: self.tokenType)
    }
}
