import "FungibleToken"

import "DeFiActions"
import "FungibleTokenConnectors"
import "AdversarialReentrancyConnectors"

import "MOET"
import "FlowToken"
import "FlowALPv0"
import "FlowALPPositionResources"
import "FlowALPModels"

/// TEST TRANSACTION — DO NOT USE IN PRODUCTION
///
/// Opens a FlowALPv0 position wired with VaultSinkHacked as its issuanceSink
/// (drawDownSink), mirroring how create_position_reentrancy.cdc wires
/// VaultSourceHacked as repaymentSource.
///
/// The sink is passed directly to createPosition() so the pool stores it
/// internally via setDrawDownSink on the InternalPosition — the only place
/// where that setter is accessible.
///
/// When the pool later calls sink.depositCapacity(from:) during a rebalance /
/// drawdown push, VaultSinkHacked calls position.depositAndPush() on the same
/// pid while the position lock is held. The reentrancy guard rejects it and
/// reverts the entire transaction.
///
/// Parameters:
///   amount              — FLOW collateral to deposit
///   vaultStoragePath    — storage path of the FLOW vault
///   pushToDrawDownSink  — whether to trigger the sink immediately on open
transaction(
    amount: UFix64,
    vaultStoragePath: StoragePath,
    pushToDrawDownSink: Bool
) {
    let collateral: @{FungibleToken.Vault}
    let sink: {DeFiActions.Sink}
    let positionManager: auth(FlowALPModels.EPositionAdmin) &FlowALPPositionResources.PositionManager
    let poolCap: Capability<auth(FlowALPModels.EParticipant) &FlowALPv0.Pool>
    let signerAccount: auth(
        LoadValue, BorrowValue, SaveValue,
        IssueStorageCapabilityController, PublishCapability, UnpublishCapability
    ) &Account

    prepare(signer: auth(
        LoadValue, BorrowValue, SaveValue,
        IssueStorageCapabilityController, PublishCapability, UnpublishCapability
    ) &Account) {
        self.signerAccount = signer

        // Withdraw collateral from the signer's vault.
        let collateralVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(
            from: vaultStoragePath
        ) ?? panic("Could not borrow vault from \(vaultStoragePath)")
        self.collateral <- collateralVault.withdraw(amount: amount)

        let liveDataStoragePath = /storage/sinkLiveDataResource
        if signer.storage.type(at: liveDataStoragePath) != nil {
            let old <- signer.storage.load<@AdversarialReentrancyConnectors.LiveData>(
                from: liveDataStoragePath
            )
            destroy old
        }
        signer.storage.save(
            <- AdversarialReentrancyConnectors.createLiveData(),
            to: liveDataStoragePath
        )
        let liveDataCap = signer.capabilities.storage.issue<
            &AdversarialReentrancyConnectors.LiveData
        >(liveDataStoragePath)

        // VaultSinkHacked requires a real depositVault capability to pass its
        // init pre-condition (depositVault.check() must be true).
        // We use the signer's MOET public capability; getSinkType() returns MOET
        // so the pool's setDrawDownSink pre-condition is also satisfied.
        let moetDepositCap = signer.capabilities.get<&{FungibleToken.Vault}>(MOET.VaultPublicPath)
        assert(
            moetDepositCap.check(),
            message: "MOET vault public capability not found — run setupMoetVault first"
        )

        // Build VaultSinkHacked. LiveData is empty at this point (pid not yet
        // known); it is populated in execute() after createPosition returns.
        self.sink = AdversarialReentrancyConnectors.VaultSinkHacked(
            max: nil,
            depositVault: moetDepositCap,
            uniqueID: nil,
            liveDataCap: liveDataCap
        )

        // Get or create PositionManager.
        if signer.storage.borrow<&FlowALPPositionResources.PositionManager>(
            from: FlowALPv0.PositionStoragePath
        ) == nil {
            let manager <- FlowALPv0.createPositionManager()
            signer.storage.save(<-manager, to: FlowALPv0.PositionStoragePath)
            let readCap = signer.capabilities.storage.issue<
                &FlowALPPositionResources.PositionManager
            >(FlowALPv0.PositionStoragePath)
            signer.capabilities.publish(readCap, at: FlowALPv0.PositionPublicPath)
        }
        self.positionManager = signer.storage.borrow<
            auth(FlowALPModels.EPositionAdmin) &FlowALPPositionResources.PositionManager
        >(from: FlowALPv0.PositionStoragePath) ?? panic("PositionManager not found")

        self.poolCap = signer.storage.load<
            Capability<auth(FlowALPModels.EParticipant) &FlowALPv0.Pool>
        >(from: FlowALPv0.PoolCapStoragePath)
            ?? panic("Could not load Pool capability — ensure EParticipant access was granted")
    }

    execute {
        let poolRef = self.poolCap.borrow() ?? panic("Could not borrow Pool capability")

        // Pass VaultSinkHacked as issuanceSink — createPosition calls
        // iPos.setDrawDownSink(issuanceSink) on the InternalPosition, which is
        // the only code path that can write the drawDownSink field.
        // pushToDrawDownSink is always false here; the adversarial trigger
        // comes from the caller after LiveData has been populated.
        let position <- poolRef.createPosition(
            funds: <-self.collateral,
            issuanceSink: self.sink,
            repaymentSource: nil,
            pushToDrawDownSink: false
        )
        let pid = position.id
        self.positionManager.addPosition(position: <-position)

        // Populate LiveData now that pid is known, so the sink can make the
        // re-entrant call when depositCapacity() is invoked.
        let liveDataCap = self.signerAccount.capabilities.storage.issue<
            &AdversarialReentrancyConnectors.LiveData
        >(/storage/sinkLiveDataResource)
        let liveData = liveDataCap.borrow() ?? panic("Cannot borrow LiveData")
        let managerCap = self.signerAccount.capabilities.storage.issue<
            auth(FungibleToken.Withdraw, FlowALPModels.EPositionAdmin) &FlowALPPositionResources.PositionManager
        >(FlowALPv0.PositionStoragePath)
        liveData.setRecursivePosition(managerCap: managerCap, pid: pid)

        self.signerAccount.storage.save(self.poolCap, to: FlowALPv0.PoolCapStoragePath)
    }
}