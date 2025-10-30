import "FlowALP"

transaction(
    dexOracleDeviationBps: UInt16?,
    allowSwappers: [String]?,
    disallowSwappers: [String]?,
    dexMaxSlippageBps: UInt64?,
    dexMaxRouteHops: UInt64?
) {
    let pool: auth(FlowALP.EGovernance) &FlowALP.Pool
    let allowTypes: [Type]?
    let disallowTypes: [Type]?

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALP.EGovernance) &FlowALP.Pool>(from: FlowALP.PoolStoragePath)
            ?? panic("Could not borrow Pool at \(FlowALP.PoolStoragePath)")

        self.allowTypes = allowSwappers == nil ? nil : allowSwappers!.map(fun (id: String): Type { return CompositeType(id)! })
        self.disallowTypes = disallowSwappers == nil ? nil : disallowSwappers!.map(fun (id: String): Type { return CompositeType(id)! })
    }

    execute {
        self.pool.setDexLiquidationConfig(
            dexOracleDeviationBps: dexOracleDeviationBps,
            allowSwappers: self.allowTypes,
            disallowSwappers: self.disallowTypes,
            dexMaxSlippageBps: dexMaxSlippageBps,
            dexMaxRouteHops: dexMaxRouteHops
        )
    }
}


