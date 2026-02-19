import "FungibleToken"

import "DeFiActions"
import "FungibleTokenConnectors"
import "AdversarialTypeSpoofingConnectors"

import "MOET"
import "FlowToken"
import "FlowALPv0"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Opens a Position with the amount of funds source from the Vault at the provided StoragePath and puts it a PositionManager
///
/// This transaction intentionally wires an **adversarial DeFiActions.Source** that attempts
/// to **spoof token types** during withdrawal. It is used to verify that the Pool and its
/// connectors correctly enforce runtime type checks and do not accept malformed or
/// mis-declared vaults from external Sources.
///
transaction(amount: UFix64, vaultStoragePath: StoragePath, pushToDrawDownSink: Bool) {

    // the funds that will be used as collateral for a FlowALPv0 loan
    let collateral: @{FungibleToken.Vault}
    // this DeFiActions Sink that will receive the loaned funds
    let sink: {DeFiActions.Sink}
    // this DeFiActions Source that will allow for the repayment of a loan if the position becomes undercollateralized
    let source: {DeFiActions.Source}
    // the position manager in the signer's account where we should store the new position
    let positionManager: auth(FlowALPv0.EPositionAdmin) &FlowALPv0.PositionManager
    // the authorized Pool capability
    let poolCap: Capability<auth(FlowALPv0.EParticipant) &FlowALPv0.Pool>
    // reference to signer's account for saving capability back
    let signerAccount: auth(LoadValue,BorrowValue, SaveValue, IssueStorageCapabilityController, PublishCapability, UnpublishCapability) &Account

    prepare(signer: auth(LoadValue,BorrowValue, SaveValue, IssueStorageCapabilityController, PublishCapability, UnpublishCapability) &Account) {
        self.signerAccount = signer
        // configure a MOET Vault to receive the loaned amount
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
        let withdrawVaultCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(/storage/flowTokenVault)
        assert(depositVaultCap.check(),
        message: "Invalid MOET Vault public Capability issued - ensure the Vault is properly configured")
        assert(withdrawVaultCap.check(),
        message: "Invalid MOET Vault private Capability issued - ensure the Vault is properly configured")

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
        self.source = AdversarialTypeSpoofingConnectors.VaultSourceFakeType(
            withdrawVault: withdrawVaultCap,
        )
        // Get or create PositionManager at constant path
        if signer.storage.borrow<&FlowALPv0.PositionManager>(from: FlowALPv0.PositionStoragePath) == nil {
            // Create new PositionManager if it doesn't exist
            let manager <- FlowALPv0.createPositionManager()
            signer.storage.save(<-manager, to: FlowALPv0.PositionStoragePath)

            // Issue and publish capabilities for the PositionManager
            let readCap = signer.capabilities.storage.issue<&FlowALPv0.PositionManager>(FlowALPv0.PositionStoragePath)

            // Publish read-only capability publicly
            signer.capabilities.publish(readCap, at: FlowALPv0.PositionPublicPath)
        }
        self.positionManager = signer.storage.borrow<auth(FlowALPv0.EPositionAdmin) &FlowALPv0.PositionManager>(from: FlowALPv0.PositionStoragePath)
            ?? panic("PositionManager not found")

        // Load the authorized Pool capability from storage
        self.poolCap = signer.storage.load<Capability<auth(FlowALPv0.EParticipant) &FlowALPv0.Pool>>(
            from: FlowALPv0.PoolCapStoragePath
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

        self.positionManager.addPosition(position: <-position)

        // Save the capability back to storage for future use
        self.signerAccount.storage.save(self.poolCap, to: FlowALPv0.PoolCapStoragePath)
    }
}
