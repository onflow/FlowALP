import "FungibleToken"
import "FungibleTokenMetadataViews"
import "MetadataViews"

import "FlowALPv1"

/// Attempt to liquidation a position by repaying `repayAmount`.
/// This TESTING-ONLY transaction allows specifying a different repayment vault type.
///
/// debtVaultIdentifier: e.g., Type<@MOET.Vault>().identifier
/// seizeVaultIdentifier: e.g., Type<@FlowToken.Vault>().identifier
transaction(pid: UInt64, purportedDebtVaultIdentifier: String, actualDebtVaultIdentifier: String, seizeVaultIdentifier: String, seizeAmount: UFix64, repayAmount: UFix64) {
    let pool: &FlowALPv1.Pool
    let receiver: &{FungibleToken.Receiver}
    let actualDebtType: Type
    let purportedDebtType: Type
    let seizeType: Type
    let repay: @{FungibleToken.Vault}

    prepare(signer: auth(BorrowValue, SaveValue, IssueStorageCapabilityController, PublishCapability, UnpublishCapability) &Account) {
        let protocolAddress = Type<@FlowALPv1.Pool>().address!
        self.pool = getAccount(protocolAddress).capabilities.borrow<&FlowALPv1.Pool>(FlowALPv1.PoolPublicPath)
            ?? panic("Could not borrow Pool at \(FlowALPv1.PoolPublicPath)")

        // Resolve types
        self.actualDebtType = CompositeType(actualDebtVaultIdentifier) ?? panic("Invalid actualDebtVaultIdentifier: \(actualDebtVaultIdentifier)")
        self.purportedDebtType = CompositeType(purportedDebtVaultIdentifier) ?? panic("Invalid purportedDebtVaultIdentifier: \(purportedDebtVaultIdentifier)")
        self.seizeType = CompositeType(seizeVaultIdentifier) ?? panic("Invalid seizeVaultIdentifier: \(seizeVaultIdentifier)")

        // Get the path and type data for the provided token type identifier
        let debtVaultData = MetadataViews.resolveContractViewFromTypeIdentifier(
            resourceTypeIdentifier: actualDebtVaultIdentifier,
            viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
        ) as? FungibleTokenMetadataViews.FTVaultData
            ?? panic("Could not construct valid FT type and view from identifier \(actualDebtVaultIdentifier)")

        let seizeVaultData = MetadataViews.resolveContractViewFromTypeIdentifier(
            resourceTypeIdentifier: seizeVaultIdentifier,
            viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
        ) as? FungibleTokenMetadataViews.FTVaultData
            ?? panic("Could not construct valid FT type and view from identifier \(seizeVaultIdentifier)")

        // Check if the service account has a vault for this token type at the correct storage path
        let debtVaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: debtVaultData.storagePath)
            ?? panic("no debt vault in storage at path \(debtVaultData.storagePath)")
        assert(debtVaultRef.balance >= repayAmount, message: "Insufficient debt token \(debtVaultRef.getType().identifier) balance \(debtVaultRef.balance)<\(repayAmount)")
        self.repay <- debtVaultRef.withdraw(amount: repayAmount)

        let seizeVaultRef = signer.capabilities.borrow<&{FungibleToken.Receiver}>(seizeVaultData.receiverPath)
            ?? panic("no seize receiver in storage at path \(seizeVaultData.receiverPath)")
        self.receiver = seizeVaultRef
    }

    execute {
        let seizedVault <- self.pool.manualLiquidation(
            pid: pid,
            debtType: self.purportedDebtType,
            seizeType: self.seizeType,
            seizeAmount: seizeAmount,
            repayment: <-self.repay
        )

        self.receiver.deposit(from: <-seizedVault)
    }
}
