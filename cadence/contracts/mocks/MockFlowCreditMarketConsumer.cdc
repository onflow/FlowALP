import "FungibleToken"

import "DeFiActions"
import "FlowCreditMarket"

/// THIS CONTRACT IS NOT SAFE FOR PRODUCTION - FOR TEST USE ONLY
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
/// A simple contract enabling the persistent storage of a Position similar to a pattern expected for platforms
/// building on top of FlowCreditMarket's lending protocol
///
access(all) contract MockFlowCreditMarketConsumer {

    /// Canonical path for where the wrapper is to be stored
    access(all) let WrapperStoragePath: StoragePath

    /// Opens a FlowCreditMarket Position and returns a PositionWrapper containing that new position
    ///
    access(all)
    fun createPositionWrapper(
        collateral: @{FungibleToken.Vault},
        issuanceSink: {DeFiActions.Sink},
        repaymentSource: {DeFiActions.Source}?,
        pushToDrawDownSink: Bool
    ): @PositionWrapper {
        let poolCap = self.account.storage.load<Capability<auth(FlowCreditMarket.EParticipant, FlowCreditMarket.EPosition) &FlowCreditMarket.Pool>>(
            from: FlowCreditMarket.PoolCapStoragePath
        ) ?? panic("Missing pool capability")

        let poolRef = poolCap.borrow() ?? panic("Invalid Pool Cap")

        let pid = poolRef.createPosition(
                funds: <-collateral,
                issuanceSink: issuanceSink,
                repaymentSource: repaymentSource,
                pushToDrawDownSink: pushToDrawDownSink
            )
        let position = FlowCreditMarket.Position(id: pid, pool: poolCap)
        self.account.storage.save(poolCap, to: FlowCreditMarket.PoolCapStoragePath)
        return <- create PositionWrapper(
            pid: pid,
            position: position
        )
    }

    access(all)
    fun getPoolCapability():
        Capability<auth(FlowCreditMarket.EParticipant, FlowCreditMarket.EPosition) & FlowCreditMarket.Pool> {

        let poolCapCopy = self.account.storage.copy<
            Capability<auth(FlowCreditMarket.EParticipant, FlowCreditMarket.EPosition) & FlowCreditMarket.Pool>
        >(from: FlowCreditMarket.PoolCapStoragePath)
            ?? panic("Missing pool capability")

        return poolCapCopy
    }

    /// A simple resource encapsulating a FlowCreditMarket Position
    access(all) resource PositionWrapper {

        access(self) let position: FlowCreditMarket.Position
        access(all) let positionID: UInt64

        init(pid: UInt64, position: FlowCreditMarket.Position) {
            self.positionID = pid
            self.position = position
        }

        /// NOT SAFE FOR PRODUCTION
        ///
        /// Returns a reference to the wrapped Position
        access(all) fun borrowPosition(): &FlowCreditMarket.Position {
            return &self.position
        }

        /// NOT SAFE FOR PRODUCTION
        ///
        /// Returns a reference to the wrapped Position with EParticipant entitlement for deposits
        access(all) fun borrowPositionForDeposit(): auth(FlowCreditMarket.EParticipant) &FlowCreditMarket.Position {
            return &self.position
        }

        access(all) fun borrowPositionForWithdraw(): auth(FungibleToken.Withdraw) &FlowCreditMarket.Position {
            return &self.position
        }
    }

    init() {
        self.WrapperStoragePath = /storage/flowCreditMarketPositionWrapper
    }
}
