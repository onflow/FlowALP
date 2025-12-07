import "FungibleToken"

import "FlowCreditMarket"
import "DeFiActions"
import "MockDexSwapper"
import "MOET"

/// TEST-ONLY: Liquidate a position via DEX using a mock swapper that withdraws MOET from a provided vault source.
/// Assumes the signer has a MOET Vault with sufficient balance.
transaction(
    pid: UInt64,
    debtType: Type,
    seizeType: Type,
    maxSeizeAmount: UFix64,
    minRepayAmount: UFix64,
    priceRatio: UFix64
) {
    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController, PublishCapability) &Account) {
        let pool = getAccount(Type<@FlowCreditMarket.Pool>().address!).capabilities
            .borrow<&FlowCreditMarket.Pool>(FlowCreditMarket.PoolPublicPath)
            ?? panic("Could not borrow Pool at \(FlowCreditMarket.PoolPublicPath)")

        // For tests, withdraw out token (debtType) from signer's MOET Vault
        let sourceCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(MOET.VaultStoragePath)

        let swapper = MockDexSwapper.Swapper(
            inVault: seizeType,
            outVault: debtType,
            vaultSource: sourceCap,
            priceRatio: priceRatio,
            uniqueID: nil
        )

        pool.liquidateViaDex(
            pid: pid,
            debtType: debtType,
            seizeType: seizeType,
            maxSeizeAmount: maxSeizeAmount,
            minRepayAmount: minRepayAmount,
            swapper: swapper,
            quote: nil
        )
    }
}


