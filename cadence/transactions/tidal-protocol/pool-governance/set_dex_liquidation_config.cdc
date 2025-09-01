import "TidalProtocol"

transaction(
    poolAddress: Address,
    dexOracleDeviationBps: UInt16?,
    allowSwappers: [String]?,
    disallowSwappers: [String]?
) {
    let pool: auth(TidalProtocol.EGovernance) &TidalProtocol.Pool
    let allowTypes: [Type]?
    let disallowTypes: [Type]?

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = getAccount(poolAddress).storage.borrow<auth(TidalProtocol.EGovernance) &TidalProtocol.Pool>(from: TidalProtocol.PoolStoragePath)
            ?? panic("Could not borrow Pool at \(TidalProtocol.PoolStoragePath)")

        self.allowTypes = allowSwappers == nil ? nil : allowSwappers!.map(fun (id: String): Type { return CompositeType(id)! })
        self.disallowTypes = disallowSwappers == nil ? nil : disallowSwappers!.map(fun (id: String): Type { return CompositeType(id)! })
    }

    execute {
        self.pool.setDexLiquidationConfig(dexOracleDeviationBps: dexOracleDeviationBps, allowSwappers: self.allowTypes, disallowSwappers: self.disallowTypes)
    }
}


