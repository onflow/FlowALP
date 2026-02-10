import "FlowCreditMarket"

transaction(
    dexOracleDeviationBps: UInt16
) {
    let pool: auth(FlowCreditMarket.EGovernance) &FlowCreditMarket.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowCreditMarket.EGovernance) &FlowCreditMarket.Pool>(from: FlowCreditMarket.PoolStoragePath)
            ?? panic("Could not borrow Pool at \(FlowCreditMarket.PoolStoragePath)")
    }

    execute {
        self.pool.setDexOracleDeviationBps(dexOracleDeviationBps: dexOracleDeviationBps)
    }
}
