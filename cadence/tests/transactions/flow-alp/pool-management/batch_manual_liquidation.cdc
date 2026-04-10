import "FungibleToken"
import "FungibleTokenMetadataViews"
import "MetadataViews"

import "FlowALPv0"
import "FlowALPModels"

/// Batch liquidate multiple positions in a single transaction
///
/// pids: Array of position IDs to liquidate
/// repaymentVaultIdentifier: e.g., Type<@FlowToken.Vault>().identifier
/// seizeVaultIdentifiers: Array of collateral vault identifiers to seize
/// seizeAmounts: Array of max seize amounts for each position
/// repayAmounts: Array of repay amounts for each position
transaction(
    pids: [UInt64],
    repaymentVaultIdentifier: String,
    seizeVaultIdentifiers: [String],
    seizeAmounts: [UFix64],
    repayAmounts: [UFix64]
) {
    let pool: auth(FlowALPModels.EParticipant) &FlowALPv0.Pool
    let repaymentType: Type
    let repaymentVaultRef: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}
    let signerAccount: auth(BorrowValue) &Account

    prepare(signer: auth(BorrowValue, SaveValue, IssueStorageCapabilityController, PublishCapability, UnpublishCapability) &Account) {
        self.signerAccount = signer

        let cap = signer.storage.borrow<&Capability<auth(FlowALPModels.EParticipant) &FlowALPv0.Pool>>(
            from: FlowALPv0.PoolCapStoragePath
        ) ?? panic("Could not borrow Pool capability from storage - ensure the signer has been granted Pool access with EParticipant entitlement")
        self.pool = cap.borrow() ?? panic("Could not borrow Pool from capability")

        self.repaymentType = CompositeType(repaymentVaultIdentifier) ?? panic("Invalid repaymentVaultIdentifier: \(repaymentVaultIdentifier)")

        let repaymentVaultData = MetadataViews.resolveContractViewFromTypeIdentifier(
            resourceTypeIdentifier: repaymentVaultIdentifier,
            viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
        ) as? FungibleTokenMetadataViews.FTVaultData
            ?? panic("Could not construct valid FT type and view from identifier \(repaymentVaultIdentifier)")

        self.repaymentVaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: repaymentVaultData.storagePath)
            ?? panic("no repayment vault in storage at path \(repaymentVaultData.storagePath)")
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

            assert(self.repaymentVaultRef.balance >= repayAmount,
                message: "Insufficient repayment token balance for position \(pid)")

            let repay <- self.repaymentVaultRef.withdraw(amount: repayAmount)

            let seizedVault <- self.pool.manualLiquidation(
                pid: pid,
                debtType: self.repaymentType,
                seizeType: seizeType,
                seizeAmount: seizeAmount,
                repayment: <-repay
            )

            totalRepaid = totalRepaid + repayAmount

            // Deposit seized collateral back to liquidator
            let seizeVaultData = MetadataViews.resolveContractViewFromTypeIdentifier(
                resourceTypeIdentifier: seizeVaultIdentifier,
                viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
            ) as? FungibleTokenMetadataViews.FTVaultData
                ?? panic("Could not resolve FTVaultData for \(seizeVaultIdentifier)")
            let liquidatorVault = self.signerAccount.storage.borrow<&{FungibleToken.Vault}>(from: seizeVaultData.storagePath)
                ?? panic("No vault at \(seizeVaultData.storagePath) to deposit seized collateral")
            liquidatorVault.deposit(from: <-seizedVault)
        }

        log("Batch liquidation completed: \(numPositions) positions, total repaid: \(totalRepaid)")
    }
}
