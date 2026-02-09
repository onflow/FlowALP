import "FungibleToken"

import "DeFiActions"
import "FungibleTokenConnectors"

import "MOET"
import "FlowCreditMarket"

/// Opens a Position, providing collateral from the provided storage vault.
/// The created Position is stored in the signer's account storage. A PositionManager is created if none already exists.
///
transaction(amount: UFix64, vaultStoragePath: StoragePath, pushToDrawDownSink: Bool, positionStoragePath: StoragePath) {

    // the funds that will be used as collateral for a FlowCreditMarket loan
    let collateral: @{FungibleToken.Vault}
    // this DeFiActions Sink that will receive the loaned funds
    let sink: {DeFiActions.Sink}
    // this DeFiActions Source that will allow for the repayment of a loan if the position becomes undercollateralized
    let source: {DeFiActions.Source}
    // the authorized Pool capability
    let poolCap: Capability<auth(FlowCreditMarket.EParticipant, FlowCreditMarket.EPosition) &FlowCreditMarket.Pool>
    // reference to signer's account for saving capability back
    let signerAccount: auth(Storage) &Account

    prepare(signer: auth(BorrowValue, Storage, Capabilities) &Account) {
        self.signerAccount = signer
        // configure a MOET Vault to receive the loaned amount (if none already exists)
        if signer.storage.type(at: MOET.VaultStoragePath) == nil {
            // save a new MOET Vault
            signer.storage.save(<-MOET.createEmptyVault(vaultType: Type<@MOET.Vault>()), to: MOET.VaultStoragePath)
            // issue un-entitled Capability
            let vaultCap = signer.capabilities.storage.issue<&MOET.Vault>(MOET.VaultStoragePath)
            // publish receiver Capability, unpublishing any that may exist to prevent collision
            signer.capabilities.unpublish(MOET.VaultPublicPath)
            signer.capabilities.publish(vaultCap, at: MOET.VaultPublicPath)
        }

        // assign a Vault Capability to be used in the VaultSink
        let depositVaultCap = signer.capabilities.get<&{FungibleToken.Vault}>(MOET.VaultPublicPath)
        let withdrawVaultCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(MOET.VaultStoragePath)

        assert(depositVaultCap.check(), message: "Invalid MOET Vault public Capability issued - ensure the Vault is properly configured")
        assert(withdrawVaultCap.check(), message: "Invalid MOET Vault private Capability issued - ensure the Vault is properly configured")

        // withdraw the collateral from the signer's stored Vault
        let collateralSource = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: vaultStoragePath)
            ?? panic("Could not borrow reference to Vault from \(vaultStoragePath)")
        self.collateral <- collateralSource.withdraw(amount: amount)
        // construct the DeFiActions Sink that will receive the loaned amount
        self.sink = FungibleTokenConnectors.VaultSink(
            max: nil,
            depositVault: depositVaultCap,
            uniqueID: nil
        )
        self.source = FungibleTokenConnectors.VaultSource(
            min: nil,
            withdrawVault: withdrawVaultCap,
            uniqueID: nil
        )

        // Load the authorized Pool capability from storage
        self.poolCap = signer.storage.load<Capability<auth(FlowCreditMarket.EParticipant, FlowCreditMarket.EPosition) &FlowCreditMarket.Pool>>(
            from: FlowCreditMarket.PoolCapStoragePath
        ) ?? panic("Could not load Pool capability from storage - ensure the signer has been granted Pool access with EParticipant entitlement")
    }

    execute {
        // Borrow the authorized Pool reference
        let poolRef = self.poolCap.borrow() ?? panic("Could not borrow Pool capability")

        // Create position
        let position <- poolRef.createPosition(
            funds: <-self.collateral,
            issuanceSink: self.sink,
            repaymentSource: self.source,
            pushToDrawDownSink: pushToDrawDownSink
        )

        let pid = position.id

        self.signerAccount.storage.save(<-position, to: positionStoragePath)
        self.signerAccount.storage.save(self.poolCap, to: FlowCreditMarket.PoolCapStoragePath)
    }
}
