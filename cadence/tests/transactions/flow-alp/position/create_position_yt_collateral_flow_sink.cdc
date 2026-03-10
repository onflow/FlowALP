import "FungibleToken"
import "FlowToken"

import "DeFiActions"
import "FungibleTokenConnectors"
import "MockYieldToken"
import "FlowALPv0"

/// Opens a Position with MockYieldToken collateral and a FLOW drawDownSink.
///
/// Demonstrates sinkType (FLOW) != defaultToken (MOET): when the position becomes
/// overcollateralised the pool borrows FLOW from reserves — not MOET — and
/// pushes it to the signer's FLOW vault.
///
transaction(amount: UFix64, pushToDrawDownSink: Bool) {

    let collateral: @{FungibleToken.Vault}
    let sink: {DeFiActions.Sink}
    let source: {DeFiActions.Source}
    let positionManager: auth(FlowALPv0.EPositionAdmin) &FlowALPv0.PositionManager
    let poolCap: Capability<auth(FlowALPv0.EParticipant, FlowALPv0.EPosition) &FlowALPv0.Pool>
    let signerAccount: auth(Storage) &Account

    prepare(signer: auth(BorrowValue, Storage, Capabilities) &Account) {
        self.signerAccount = signer

        // Withdraw MockYieldToken as collateral
        let ytVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &MockYieldToken.Vault>(
            from: MockYieldToken.VaultStoragePath
        ) ?? panic("No MockYieldToken.Vault in storage")
        self.collateral <- ytVault.withdraw(amount: amount)

        // Sink: borrowed FLOW is pushed into the signer's FLOW vault
        let flowDepositCap = signer.capabilities.get<&{FungibleToken.Vault}>(/public/flowTokenReceiver)
        let flowWithdrawCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(/storage/flowTokenVault)

        self.sink = FungibleTokenConnectors.VaultSink(
            max: nil,
            depositVault: flowDepositCap,
            uniqueID: nil
        )
        // Source: repayment of FLOW debt drawn from the signer's FLOW vault
        self.source = FungibleTokenConnectors.VaultSource(
            min: nil,
            withdrawVault: flowWithdrawCap,
            uniqueID: nil
        )

        if signer.storage.borrow<&FlowALPv0.PositionManager>(from: FlowALPv0.PositionStoragePath) == nil {
            let manager <- FlowALPv0.createPositionManager()
            signer.storage.save(<-manager, to: FlowALPv0.PositionStoragePath)
            let readCap = signer.capabilities.storage.issue<&FlowALPv0.PositionManager>(FlowALPv0.PositionStoragePath)
            signer.capabilities.publish(readCap, at: FlowALPv0.PositionPublicPath)
        }

        self.positionManager = signer.storage.borrow<auth(FlowALPv0.EPositionAdmin) &FlowALPv0.PositionManager>(
            from: FlowALPv0.PositionStoragePath
        ) ?? panic("PositionManager not found")

        self.poolCap = signer.storage.load<Capability<auth(FlowALPv0.EParticipant, FlowALPv0.EPosition) &FlowALPv0.Pool>>(
            from: FlowALPv0.PoolCapStoragePath
        ) ?? panic("No Pool capability at PoolCapStoragePath")
    }

    execute {
        let pool = self.poolCap.borrow() ?? panic("Could not borrow Pool capability")
        let position <- pool.createPosition(
            funds: <-self.collateral,
            issuanceSink: self.sink,
            repaymentSource: self.source,
            pushToDrawDownSink: pushToDrawDownSink
        )
        self.positionManager.addPosition(position: <-position)
        self.signerAccount.storage.save(self.poolCap, to: FlowALPv0.PoolCapStoragePath)
    }
}
