import "TidalProtocol"

transaction(
    tokenTypeIdentifier: String,
    insuranceRate: UFix64
) {
    let pool: auth(TidalProtocol.EGovernance) &TidalProtocol.Pool
    let tokenType: Type

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(TidalProtocol.EGovernance) &TidalProtocol.Pool>(from: TidalProtocol.PoolStoragePath)
            ?? panic("Could not borrow Pool at \(TidalProtocol.PoolStoragePath)")
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")
    }

    execute {
        self.pool.setInsuranceRate(tokenType: self.tokenType, insuranceRate: insuranceRate)
    }
}


