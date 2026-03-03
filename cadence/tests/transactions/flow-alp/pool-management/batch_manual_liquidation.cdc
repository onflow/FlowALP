import "FungibleToken"
import "FungibleTokenMetadataViews"
import "MetadataViews"

import "FlowALPv0"

/// Batch liquidate multiple positions in a single transaction
///
/// pids: Array of position IDs to liquidate
/// debtVaultIdentifier: e.g., Type<@FlowToken.Vault>().identifier
/// seizeVaultIdentifiers: Array of collateral vault identifiers to seize
/// seizeAmounts: Array of max seize amounts for each position
/// repayAmounts: Array of repay amounts for each position
transaction(
    pids: [UInt64],
    debtVaultIdentifier: String,
    seizeVaultIdentifiers: [String],
    seizeAmounts: [UFix64],
    repayAmounts: [UFix64]
) {
    let pool: &FlowALPv0.Pool
    let debtType: Type
    let debtVaultRef: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}

    prepare(signer: auth(BorrowValue, SaveValue, IssueStorageCapabilityController, PublishCapability, UnpublishCapability) &Account) {
        let protocolAddress = Type<@FlowALPv0.Pool>().address!
        self.pool = getAccount(protocolAddress).capabilities.borrow<&FlowALPv0.Pool>(FlowALPv0.PoolPublicPath)
            ?? panic("Could not borrow Pool at \(FlowALPv0.PoolPublicPath)")

        self.debtType = CompositeType(debtVaultIdentifier) ?? panic("Invalid debtVaultIdentifier: \(debtVaultIdentifier)")

        let debtVaultData = MetadataViews.resolveContractViewFromTypeIdentifier(
            resourceTypeIdentifier: debtVaultIdentifier,
            viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
        ) as? FungibleTokenMetadataViews.FTVaultData
            ?? panic("Could not construct valid FT type and view from identifier \(debtVaultIdentifier)")

        self.debtVaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: debtVaultData.storagePath)
            ?? panic("no debt vault in storage at path \(debtVaultData.storagePath)")
    }

    execute {
        let numPositions = pids.length
        assert(seizeVaultIdentifiers.length == numPositions, message: "seizeVaultIdentifiers length mismatch")
        assert(seizeAmounts.length == numPositions, message: "seizeAmounts length mismatch")
        assert(repayAmounts.length == numPositions, message: "repayAmounts length mismatch")

        var totalRepaid = 0.0

        for i in InclusiveRange(0, numPositions - 1) {
            let pid = pids[i]
            let seizeVaultIdentifier = seizeVaultIdentifiers[i]
            let seizeAmount = seizeAmounts[i]
            let repayAmount = repayAmounts[i]

            let seizeType = CompositeType(seizeVaultIdentifier)
                ?? panic("Invalid seizeVaultIdentifier: \(seizeVaultIdentifier)")

            assert(self.debtVaultRef.balance >= repayAmount,
                message: "Insufficient debt token balance for position \(pid)")

            let repay <- self.debtVaultRef.withdraw(amount: repayAmount)

            let seizedVault <- self.pool.manualLiquidation(
                pid: pid,
                debtType: self.debtType,
                seizeType: seizeType,
                seizeAmount: seizeAmount,
                repayment: <-repay
            )

            totalRepaid = totalRepaid + repayAmount

            // Deposit seized collateral back to liquidator
            // For simplicity, we'll just destroy it in this test transaction
            // In production, you'd want to properly handle the seized collateral
            destroy seizedVault
        }

        log("Batch liquidation completed: \(numPositions) positions, total repaid: \(totalRepaid)")
    }
}
