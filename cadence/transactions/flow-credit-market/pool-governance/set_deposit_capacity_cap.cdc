import "FlowCreditMarket"

/// Sets the deposit capacity cap for a token type
///
transaction(tokenTypeIdentifier: String, cap: UFix64) {
    let tokenType: Type
    let pool: auth(FlowCreditMarket.EGovernance) &FlowCreditMarket.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")
        self.pool = signer.storage.borrow<auth(FlowCreditMarket.EGovernance) &FlowCreditMarket.Pool>(from: FlowCreditMarket.PoolStoragePath)
            ?? panic("Could not borrow reference to Pool from \(FlowCreditMarket.PoolStoragePath)")
    }

    execute {
        self.pool.setDepositCapacityCap(tokenType: self.tokenType, cap: cap)
    }
}

