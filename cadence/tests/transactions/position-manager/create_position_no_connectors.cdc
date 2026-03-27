import "FungibleToken"

import "FlowALPv0"
import "FlowALPPositionResources"
import "FlowALPModels"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Creates a position without a topUpSource or drawDownSink.
///
transaction(amount: UFix64, vaultStoragePath: StoragePath) {

    let collateral: @{FungibleToken.Vault}
    let positionManager: auth(FlowALPModels.EPositionAdmin) &FlowALPPositionResources.PositionManager
    let poolCap: Capability<auth(FlowALPModels.EParticipant, FlowALPModels.EPosition) &FlowALPv0.Pool>
    let signerAccount: auth(Storage) &Account

    prepare(signer: auth(BorrowValue, Storage, Capabilities) &Account) {
        self.signerAccount = signer

        let collateralSource = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: vaultStoragePath)
            ?? panic("Could not borrow reference to Vault from \(vaultStoragePath)")
        self.collateral <- collateralSource.withdraw(amount: amount)

        if signer.storage.borrow<&FlowALPPositionResources.PositionManager>(from: FlowALPv0.PositionStoragePath) == nil {
            let manager <- FlowALPv0.createPositionManager()
            signer.storage.save(<-manager, to: FlowALPv0.PositionStoragePath)
            let readCap = signer.capabilities.storage.issue<&FlowALPPositionResources.PositionManager>(FlowALPv0.PositionStoragePath)
            signer.capabilities.publish(readCap, at: FlowALPv0.PositionPublicPath)
        }
        self.positionManager = signer.storage.borrow<auth(FlowALPModels.EPositionAdmin) &FlowALPPositionResources.PositionManager>(from: FlowALPv0.PositionStoragePath)
            ?? panic("PositionManager not found")

        self.poolCap = signer.storage.load<Capability<auth(FlowALPModels.EParticipant, FlowALPModels.EPosition) &FlowALPv0.Pool>>(
            from: FlowALPv0.PoolCapStoragePath
        ) ?? panic("Could not load Pool capability from storage")
    }

    execute {
        let poolRef = self.poolCap.borrow() ?? panic("Could not borrow Pool capability")

        let position <- poolRef.createPosition(
            funds: <-self.collateral,
            issuanceSink: nil,
            repaymentSource: nil,
            pushToDrawDownSink: false
        )

        self.positionManager.addPosition(position: <-position)
        self.signerAccount.storage.save(self.poolCap, to: FlowALPv0.PoolCapStoragePath)
    }
}
