import "FungibleToken"
import "FungibleTokenMetadataViews"
import "MetadataViews"

import "FlowALPv0"
import "FlowALPModels"
import "MockDexSwapper"

/// TEST-ONLY: Batch liquidate multiple positions using the stored MockDexSwapper as the debt
/// repayment source. The swapper's vaultSource (configured via setMockDexPriceForPair) withdraws
/// the required debt tokens, so the transaction signer needs no debt tokens upfront.
///
/// Positions are liquidated in the order provided (caller is responsible for ordering by priority).
///
/// pids: Array of position IDs to liquidate
/// debtVaultIdentifier: e.g., Type<@FlowToken.Vault>().identifier
/// seizeVaultIdentifiers: Array of collateral vault identifiers to seize (one per position)
/// seizeAmounts: Array of collateral amounts to seize from each position
/// repayAmounts: Array of debt amounts to repay for each position (sourced from the DEX)
transaction(
    pids: [UInt64],
    repayVaultIdentifier: String,
    seizeVaultIdentifiers: [String],
    seizeAmounts: [UFix64],
    repayAmounts: [UFix64]
) {
    let pool: auth(FlowALPModels.EParticipant) &FlowALPv0.Pool
    let debtType: Type
    let signerAccount: auth(BorrowValue) &Account

    prepare(signer: auth(BorrowValue) &Account) {
        let cap = signer.storage.borrow<&Capability<auth(FlowALPModels.EParticipant) &FlowALPv0.Pool>>(
            from: FlowALPv0.PoolCapStoragePath
        ) ?? panic("Could not borrow Pool capability from storage - ensure the signer has been granted Pool access with EParticipant entitlement")
        self.pool = cap.borrow() ?? panic("Could not borrow Pool from capability")

        self.debtType = CompositeType(repayVaultIdentifier)
            ?? panic("Invalid debtVaultIdentifier: \(repayVaultIdentifier)")

        self.signerAccount = signer
    }

    execute {
        let numPositions = pids.length
        assert(seizeVaultIdentifiers.length == numPositions, message: "seizeVaultIdentifiers length mismatch")
        assert(seizeAmounts.length == numPositions, message: "seizeAmounts length mismatch")
        assert(repayAmounts.length == numPositions, message: "repayAmounts length mismatch")

        var totalRepaid = 0.0

        for idx in InclusiveRange(0, numPositions - 1)  {
            let pid = pids[idx]
            let seizeVaultIdentifier = seizeVaultIdentifiers[idx]
            let seizeAmount = seizeAmounts[idx]
            let repayAmount = repayAmounts[idx]

            let seizeType = CompositeType(seizeVaultIdentifier)
                ?? panic("Invalid seizeVaultIdentifier: \(seizeVaultIdentifier)")

            // Retrieve the stored MockDexSwapper for this collateral → debt pair.
            // The swapper's vaultSource (protocolAccount's vault) provides the debt tokens.
            let swapper = MockDexSwapper.getSwapper(inType: seizeType, outType: self.debtType)
                ?? panic("No MockDexSwapper configured for \(seizeVaultIdentifier) -> \(repayVaultIdentifier)")

            // Build an exact quote for the repayAmount we need from the swapper's vaultSource
            let swapQuote = MockDexSwapper.BasicQuote(
                inType: seizeType,
                outType: self.debtType,
                inAmount: 0.0,
                outAmount: repayAmount
            )

            // Create an empty collateral vault as a dummy swap input — MockDexSwapper burns it
            // and withdraws repayAmount debt tokens from its configured vaultSource instead.
            let seizeVaultData = MetadataViews.resolveContractViewFromTypeIdentifier(
                resourceTypeIdentifier: seizeVaultIdentifier,
                viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
            ) as? FungibleTokenMetadataViews.FTVaultData
                ?? panic("Could not resolve FTVaultData for \(seizeVaultIdentifier)")
            let emptyCollateralVault <- seizeVaultData.createEmptyVault()

            // Swap: burns emptyCollateralVault, withdraws repayAmount from vaultSource
            let repayVault <- swapper.swap(quote: swapQuote, inVault: <-emptyCollateralVault)

            // Execute the liquidation: pool seizes collateral, caller provides repayment
            let seizedVault <- self.pool.manualLiquidation(
                pid: pid,
                debtType: self.debtType,
                seizeType: seizeType,
                seizeAmount: seizeAmount,
                repayment: <-repayVault
            )

            totalRepaid = totalRepaid + repayAmount

            // Deposit seized collateral back to liquidator
            let liquidatorVault = self.signerAccount.storage.borrow<&{FungibleToken.Vault}>(from: seizeVaultData.storagePath)
                ?? panic("No vault at \(seizeVaultData.storagePath) to deposit seized collateral")
            liquidatorVault.deposit(from: <-seizedVault)
        }

        log("Batch DEX liquidation completed: \(numPositions) positions, total repaid: \(totalRepaid)")
    }
}
