import "FlowALPv0"
import "MockDexSwapper"
import "DeFiActions"

/// Sets the Pool's DEX swapper provider to MockDexSwapper.SwapperProvider.
/// Must be signed by the Pool governance account (the account storing the Pool resource).
transaction() {
    let pool: auth(FlowALPv0.EGovernance) &FlowALPv0.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALPv0.EGovernance) &FlowALPv0.Pool>(from: FlowALPv0.PoolStoragePath)
            ?? panic("Could not borrow reference to Pool from ".concat(FlowALPv0.PoolStoragePath.toString()))
    }

    execute {
        let dex = MockDexSwapper.SwapperProvider()
        self.pool.setDEX(dex: dex)
    }
}
