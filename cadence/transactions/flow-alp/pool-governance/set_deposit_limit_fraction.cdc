import "FlowALPv0"
import "FlowALPModels"

transaction(
    tokenTypeIdentifier: String,
    fraction: UFix64
) {
    let pool: auth(FlowALPModels.EGovernance) &FlowALPv0.Pool
    let tokenType: Type

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALPModels.EGovernance) &FlowALPv0.Pool>(from: FlowALPv0.PoolStoragePath)
            ?? panic("Could not borrow Pool at \(FlowALPv0.PoolStoragePath)")
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")
    }

    execute {
        self.pool.setDepositLimitFraction(tokenType: self.tokenType, fraction: fraction)
    }
}


