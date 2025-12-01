import "FlowCreditMarket"

transaction(
    tokenTypeIdentifier: String,
    insuranceRate: UFix64
) {
    let pool: auth(FlowCreditMarket.EGovernance) &FlowCreditMarket.Pool
    let tokenType: Type

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowCreditMarket.EGovernance) &FlowCreditMarket.Pool>(from: FlowCreditMarket.PoolStoragePath)
            ?? panic("Could not borrow Pool at \(FlowCreditMarket.PoolStoragePath)")
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")
    }

    execute {
        self.pool.setInsuranceRate(tokenType: self.tokenType, insuranceRate: insuranceRate)
    }
}


