import "FlowALPv0"
import "FlowALPModels"

/// Sets the deposit flat hourlyRate for a token type
///
transaction(tokenTypeIdentifier: String, hourlyRate: UFix64) {
    let tokenType: Type
    let pool: auth(FlowALPModels.EGovernance) &FlowALPv0.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")
        self.pool = signer.storage.borrow<auth(FlowALPModels.EGovernance) &FlowALPv0.Pool>(from: FlowALPv0.PoolStoragePath)
            ?? panic("Could not borrow reference to Pool from \(FlowALPv0.PoolStoragePath)")
    }

    execute {
        self.pool.setDepositRate(tokenType: self.tokenType, hourlyRate: hourlyRate)
    }
}

