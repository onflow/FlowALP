import "FlowALPv0"
import "BandOracleConnectors"
import "DeFiActions"
import "FungibleTokenConnectors"
import "FungibleToken"

transaction() {
    let pool: auth(FlowALPv0.EGovernance) &FlowALPv0.Pool
    let oracle: {DeFiActions.PriceOracle}

    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALPv0.EGovernance) &FlowALPv0.Pool>(from: FlowALPv0.PoolStoragePath)
            ?? panic("Could not borrow reference to Pool from \(FlowALPv0.PoolStoragePath) - ensure a Pool has been configured")
        let defaultToken = self.pool.getDefaultToken()

        let vaultCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(/storage/flowTokenVault)
        let feeSource = FungibleTokenConnectors.VaultSource(min: nil, withdrawVault: vaultCap, uniqueID: nil)
        self.oracle = BandOracleConnectors.PriceOracle(
            unitOfAccount: defaultToken,
            staleThreshold: 3600,
            feeSource: feeSource,
            uniqueID: nil,
        )
    }

    execute {
        self.pool.setPriceOracle(
            self.oracle
        )
    }
}
