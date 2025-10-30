import "FlowALP"

transaction(
    tokenTypeIdentifier: String,
    fraction: UFix64
) {
    let pool: auth(FlowALP.EGovernance) &FlowALP.Pool
    let tokenType: Type

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALP.EGovernance) &FlowALP.Pool>(from: FlowALP.PoolStoragePath)
            ?? panic("Could not borrow Pool at \(FlowALP.PoolStoragePath)")
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")
    }

    execute {
        self.pool.setDepositLimitFraction(tokenType: self.tokenType, fraction: fraction)
    }
}


