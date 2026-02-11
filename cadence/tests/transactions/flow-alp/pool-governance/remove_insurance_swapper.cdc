import "FlowALPv1"

/// TEST-ONLY: Removes the insurance swapper for a given token type.
///
/// ⚠️ **Important:** This transaction intentionally does **not** set the
/// insurance rate to `0.0` before removing the insurance swapper.
///
/// As a result, this transaction **may fail** if the insurance rate for the
/// given token type is still set and greater than zero. This reflects the
/// expected protocol behavior when insurance accrual remains enabled but
/// no swapper is configured.
///
/// This transaction exists solely for **testing purposes** to validate
/// failure scenarios and invariants around insurance configuration.
/// It MUST NOT be used as a reference for production or governance flows.
///
/// @param tokenTypeIdentifier: The fully-qualified Cadence type identifier
transaction(tokenTypeIdentifier: String) {
    let pool: auth(FlowALPv1.EGovernance) &FlowALPv1.Pool
    let tokenType: Type
    
    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALPv1.EGovernance) &FlowALPv1.Pool>(from: FlowALPv1.PoolStoragePath)
            ?? panic("Could not borrow Pool at \(FlowALPv1.PoolStoragePath)")
        
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")
    }
    
    execute {
        self.pool.setInsuranceSwapper(tokenType: self.tokenType, swapper: nil)
    }
}
