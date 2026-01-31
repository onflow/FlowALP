import "FungibleToken"

import "DeFiActions"
import "FungibleTokenConnectors"

import "MOET"
import "FlowCreditMarket"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Opens a Position using the public participant capability (no beta grant required)
/// and stores it directly in the user's PositionManager
///
transaction(amount: UFix64, vaultStoragePath: StoragePath, pushToDrawDownSink: Bool) {

    // the funds that will be used as collateral for a FlowCreditMarket loan
    let collateral: @{FungibleToken.Vault}
    // this DeFiActions Sink that will receive the loaned funds
    let sink: {DeFiActions.Sink}
    // DEBUG: this DeFiActions Source that will allow for the repayment of a loan if the position becomes undercollateralized
    let source: {DeFiActions.Source}
    // the signer's account in which to store the Position
    let account: auth(Storage, Capabilities) &Account

    prepare(signer: auth(BorrowValue, Storage, Capabilities) &Account) {
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
        let withdrawVaultCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(MOET.VaultStoragePath)
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
        self.source = FungibleTokenConnectors.VaultSource(
            min: nil,
            withdrawVault: withdrawVaultCap,
            uniqueID: nil
        )

        // assign the signer's account enabling the execute block to save the wrapper
        self.account = signer
    }

    execute {
        // Borrow public Pool reference (no beta grant required)
        let protocolAddress = Type<@FlowCreditMarket.Pool>().address!
        let poolRef = getAccount(protocolAddress)
            .capabilities.borrow<&FlowCreditMarket.Pool>(
                FlowCreditMarket.PoolPublicPath
            ) ?? panic("Could not borrow Pool public capability")

        // Create position - createPosition is now access(all) so can be called through public capability
        let position <- poolRef.createPosition(
            funds: <-self.collateral,
            issuanceSink: self.sink,
            repaymentSource: self.source,
            pushToDrawDownSink: pushToDrawDownSink
        )

        let pid = position.id

        // Get or create PositionManager at constant path
        if self.account.storage.borrow<&FlowCreditMarket.PositionManager>(from: FlowCreditMarket.PositionStoragePath) == nil {
            // Create new PositionManager if it doesn't exist
            let manager <- FlowCreditMarket.createPositionManager()
            self.account.storage.save(<-manager, to: FlowCreditMarket.PositionStoragePath)

            // Issue and publish capabilities for the PositionManager
            let depositCap = self.account.capabilities.storage.issue<auth(FlowCreditMarket.EPositionDeposit) &FlowCreditMarket.PositionManager>(FlowCreditMarket.PositionStoragePath)
            let withdrawCap = self.account.capabilities.storage.issue<auth(FlowCreditMarket.EPositionWithdraw) &FlowCreditMarket.PositionManager>(FlowCreditMarket.PositionStoragePath)
            let manageCap = self.account.capabilities.storage.issue<auth(FlowCreditMarket.EPositionManage) &FlowCreditMarket.PositionManager>(FlowCreditMarket.PositionStoragePath)
            let readCap = self.account.capabilities.storage.issue<&FlowCreditMarket.PositionManager>(FlowCreditMarket.PositionStoragePath)

            // Publish read-only capability publicly
            self.account.capabilities.publish(readCap, at: FlowCreditMarket.PositionPublicPath)
        }

        // Add position to the manager
        let manager = self.account.storage.borrow<&FlowCreditMarket.PositionManager>(from: FlowCreditMarket.PositionStoragePath)
            ?? panic("PositionManager not found")
        manager.addPosition(position: <-position)

        // Position is now stored in PositionManager at FlowCreditMarket.PositionStoragePath
        log("Created and stored Position with ID: ".concat(pid.toString()))
    }
}
