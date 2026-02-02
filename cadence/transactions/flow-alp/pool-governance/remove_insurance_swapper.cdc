import "FlowALPv1"

/// Removes the insurance swapper for a given token type.
///
/// This transaction sets the insurance rate to `0.0`
/// before removing the insurance swapper. 
///
/// This transaction represents the **recommended and safe way**
/// to disable insurance for a token type when the protocol does
/// not automatically zero out the insurance rate upon swapper removal.
///
/// @param tokenTypeIdentifier: The token type to configure (e.g., "A.0x07.MOET.Vault")
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
        self.pool.setInsuranceRate(tokenType: self.tokenType, insuranceRate: 0.0)
        self.pool.setInsuranceSwapper(tokenType: self.tokenType, swapper: nil)
    }
}
