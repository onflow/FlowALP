import "FungibleToken"
import "FlowToken"
import "FungibleTokenConnectors"
import "BandOracleConnectors"

/// Creates a BandOracleConnectors.PriceOracle with the given unitOfAccount and
/// an empty FlowToken vault as the fee source, saves it to storage, and
/// publishes a capability at /public/bandOraclePriceOracle
transaction(unitOfAccount: Type) {
    prepare(signer: auth(BorrowValue, SaveValue, Capabilities, IssueStorageCapabilityController, PublishCapability) &Account) {
        let flowTokenAccount = getAccount(Type<@FlowToken.Vault>().address!)
        let flowTokenRef = flowTokenAccount.contracts.borrow<&{FungibleToken}>(name: "FlowToken")
            ?? panic("FlowToken contract not found")
        let emptyVault <- flowTokenRef.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        signer.storage.save(<-emptyVault, to: /storage/flowFeeVault)

        let cap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(/storage/flowFeeVault)
        let feeSource = FungibleTokenConnectors.VaultSource(min: nil, withdrawVault: cap, uniqueID: nil)
        let oracle = BandOracleConnectors.PriceOracle(
            unitOfAccount: unitOfAccount,
            staleThreshold: 3600,
            feeSource: feeSource,
            uniqueID: nil
        )
        signer.storage.save(oracle, to: /storage/bandOraclePriceOracle)
        let oracleCap = signer.capabilities.storage.issue<&BandOracleConnectors.PriceOracle>(/storage/bandOraclePriceOracle)
        signer.capabilities.publish(oracleCap, at: /public/bandOraclePriceOracle)
    }
}
