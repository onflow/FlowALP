import "FlowALPv1"

/// Sets the deposit flat hourlyRate for a token type
///
transaction(tokenTypeIdentifier: String, hourlyRate: UFix64) {
    let tokenType: Type
    let pool: auth(FlowALPv1.EGovernance) &FlowALPv1.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")
        self.pool = signer.storage.borrow<auth(FlowALPv1.EGovernance) &FlowALPv1.Pool>(from: FlowALPv1.PoolStoragePath)
            ?? panic("Could not borrow reference to Pool from \(FlowALPv1.PoolStoragePath)")
    }

    execute {
        self.pool.setDepositRate(tokenType: self.tokenType, hourlyRate: hourlyRate)
    }
}

