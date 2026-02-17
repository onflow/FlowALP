import "FlowALPv1"

transaction(
    tokenTypeIdentifier: String,
    fraction: UFix64
) {
    let pool: auth(FlowALPv1.EGovernance) &FlowALPv1.Pool
    let tokenType: Type

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALPv1.EGovernance) &FlowALPv1.Pool>(from: FlowALPv1.PoolStoragePath)
            ?? panic("Could not borrow Pool at \(FlowALPv1.PoolStoragePath)")
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")
    }

    execute {
        self.pool.setDepositLimitFraction(tokenType: self.tokenType, fraction: fraction)
    }
}


