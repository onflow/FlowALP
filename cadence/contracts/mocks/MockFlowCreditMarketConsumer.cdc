import "FungibleToken"

import "DeFiActions"
import "FlowCreditMarket"

/// THIS CONTRACT IS NOT SAFE FOR PRODUCTION - FOR TEST USE ONLY
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
/// A simple contract demonstrating how to create and store Position resources
/// for platforms building on top of FlowCreditMarket's lending protocol
///
access(all) contract MockFlowCreditMarketConsumer {

    /// Opens a FlowCreditMarket Position and stores it in a PositionManager
    /// Returns the position ID for reference
    ///
    access(all)
    fun createAndStorePosition(
        account: auth(Storage, Capabilities) &Account,
        collateral: @{FungibleToken.Vault},
        issuanceSink: {DeFiActions.Sink},
        repaymentSource: {DeFiActions.Source}?,
        pushToDrawDownSink: Bool
    ): UInt64 {
        let poolCap = self.account.storage.load<Capability<auth(FlowCreditMarket.EParticipant) &FlowCreditMarket.Pool>>(
            from: FlowCreditMarket.PoolCapStoragePath
        ) ?? panic("Missing pool capability")

        let poolRef = poolCap.borrow() ?? panic("Invalid Pool Cap")

        // Create position - returns a Position resource
        let position <- poolRef.createPosition(
            funds: <-collateral,
            issuanceSink: issuanceSink,
            repaymentSource: repaymentSource,
            pushToDrawDownSink: pushToDrawDownSink
        )

        let pid = position.id

        // Get or create PositionManager at constant path
        if account.storage.borrow<&FlowCreditMarket.PositionManager>(from: FlowCreditMarket.PositionStoragePath) == nil {
            // Create new PositionManager if it doesn't exist
            let manager <- FlowCreditMarket.createPositionManager()
            account.storage.save(<-manager, to: FlowCreditMarket.PositionStoragePath)

            // Issue and publish capabilities for the PositionManager
            let depositCap = account.capabilities.storage.issue<auth(FlowCreditMarket.EPositionDeposit) &FlowCreditMarket.PositionManager>(FlowCreditMarket.PositionStoragePath)
            let withdrawCap = account.capabilities.storage.issue<auth(FlowCreditMarket.EPositionWithdraw) &FlowCreditMarket.PositionManager>(FlowCreditMarket.PositionStoragePath)
            let manageCap = account.capabilities.storage.issue<auth(FlowCreditMarket.EPositionManage) &FlowCreditMarket.PositionManager>(FlowCreditMarket.PositionStoragePath)
            let readCap = account.capabilities.storage.issue<&FlowCreditMarket.PositionManager>(FlowCreditMarket.PositionStoragePath)

            // Publish read-only capability publicly
            account.capabilities.publish(readCap, at: FlowCreditMarket.PositionPublicPath)
        }

        // Add position to the manager
        let manager = account.storage.borrow<&FlowCreditMarket.PositionManager>(from: FlowCreditMarket.PositionStoragePath)
            ?? panic("PositionManager not found")
        manager.addPosition(position: <-position)

        // Store the pool capability back
        self.account.storage.save(poolCap, to: FlowCreditMarket.PoolCapStoragePath)

        return pid
    }

    init() {
        // No storage paths needed since Positions are stored in PositionManager using constant paths
    }
}
