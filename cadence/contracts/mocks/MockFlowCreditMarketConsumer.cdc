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

    /// Opens a FlowCreditMarket Position and stores it directly in the account
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

        // Create position - now returns a Position resource
        let position <- poolRef.createPosition(
            funds: <-collateral,
            issuanceSink: issuanceSink,
            repaymentSource: repaymentSource,
            pushToDrawDownSink: pushToDrawDownSink
        )

        let pid = position.id

        // Store the Position resource in the user's account
        let storagePath = FlowCreditMarket.getPositionStoragePath(pid: pid)
        account.storage.save(<-position, to: storagePath)

        // Issue and publish capabilities for the Position
        let depositCap = account.capabilities.storage.issue<auth(FlowCreditMarket.EPositionDeposit) &FlowCreditMarket.Position>(storagePath)
        let withdrawCap = account.capabilities.storage.issue<auth(FlowCreditMarket.EPositionWithdraw) &FlowCreditMarket.Position>(storagePath)
        let configureCap = account.capabilities.storage.issue<auth(FlowCreditMarket.EPositionConfigure) &FlowCreditMarket.Position>(storagePath)
        let manageCap = account.capabilities.storage.issue<auth(FlowCreditMarket.EPositionManage) &FlowCreditMarket.Position>(storagePath)
        let readCap = account.capabilities.storage.issue<&FlowCreditMarket.Position>(storagePath)

        // Publish read-only capability publicly
        let publicPath = FlowCreditMarket.getPositionPublicPath(pid: pid)
        account.capabilities.publish(readCap, at: publicPath)

        // Store the pool capability back
        self.account.storage.save(poolCap, to: FlowCreditMarket.PoolCapStoragePath)

        return pid
    }

    init() {
        // No storage paths needed since Positions are stored directly using FlowCreditMarket helper functions
    }
}
