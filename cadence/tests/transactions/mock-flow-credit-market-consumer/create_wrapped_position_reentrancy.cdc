import "FungibleToken"

import "DeFiActions"
import "FungibleTokenConnectors"
import "AdversarialReentrancyConnectors"

import "MOET"
import "FlowToken"
import "MockFlowCreditMarketConsumer"
import "FlowCreditMarket"

/// TEST TRANSACTION - DO NOT USE IN PRODUCTION
///
/// Opens a FlowCreditMarket position using collateral withdrawn from the signer’s vault and
/// wraps it in a `MockFlowCreditMarketConsumer.PositionWrapper`.
///
/// This transaction intentionally wires an **adversarial DeFiActions.Source** that attempts
/// to re-enter the Pool during `withdrawAndPull` flows. It is used to validate that the Pool’s
/// reentrancy protections (position locks) correctly reject recursive deposit/withdraw behavior.
///
///
transaction(amount: UFix64, vaultStoragePath: StoragePath, pushToDrawDownSink: Bool){
    // the funds that will be used as collateral for a FlowCreditMarket loan
    let collateral: @{FungibleToken.Vault}
    // this DeFiActions Sink that will receive the loaned funds
    let sink: {DeFiActions.Sink}
    // DEBUG: this DeFiActions Source that will allow for the repayment of a loan if the position becomes undercollateralized
    let source: {DeFiActions.Source}
    // the signer's account in which to store a PositionWrapper
    let account: auth(SaveValue) &Account

    prepare(signer: auth(BorrowValue, SaveValue, IssueStorageCapabilityController, PublishCapability, UnpublishCapability) &Account) {
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
        let liveData <- AdversarialReentrancyConnectors.createLiveData()

        let storagePath = /storage/myLiveDataResource
        signer.storage.save(<-liveData, to: storagePath)

        let liveDataCap = signer.capabilities.storage.issue<&AdversarialReentrancyConnectors.LiveData>(storagePath)

        self.source = AdversarialReentrancyConnectors.VaultSourceHacked(
            min: nil,
            withdrawVault: withdrawVaultCap,
            uniqueID: nil,
            liveDataCap: liveDataCap
        )

        // assign the signer's account enabling the execute block to save the wrapper
        self.account = signer
    }

    execute {
        // open a position & save in the Wrapper
        let wrapper <- MockFlowCreditMarketConsumer.createPositionWrapper(
            collateral: <-self.collateral,
            issuanceSink: self.sink,
            repaymentSource: self.source,
            pushToDrawDownSink: pushToDrawDownSink
        )
        let poolCapability = MockFlowCreditMarketConsumer.getPoolCapability()
        log("Pool capability: \(poolCapability.check())")
        let sourceRef = self.source as! AdversarialReentrancyConnectors.VaultSourceHacked
        
        let liveData = sourceRef.liveDataCap.borrow() ?? panic("cant borrow LiveData")
        liveData.setRecursivePool(poolCapability)
        liveData.setRecursivePositionID(wrapper.positionID)

        self.account.storage.save(<-wrapper, to: MockFlowCreditMarketConsumer.WrapperStoragePath)
    }
}
