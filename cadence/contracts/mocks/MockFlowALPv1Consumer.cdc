import "FungibleToken"

import "DeFiActions"
import "FlowALPv1"

/// THIS CONTRACT IS NOT SAFE FOR PRODUCTION - FOR TEST USE ONLY
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
/// A simple contract enabling the persistent storage of a Position similar to a pattern expected for platforms
/// building on top of FlowALPv1's lending protocol
///
access(all) contract MockFlowALPv1Consumer {

    /// Canonical path for where the wrapper is to be stored
    access(all) let WrapperStoragePath: StoragePath

    /// Opens a FlowALPv1 Position and returns a PositionWrapper containing that new position
    ///
    access(all)
    fun createPositionWrapper(
        collateral: @{FungibleToken.Vault},
        issuanceSink: {DeFiActions.Sink},
        repaymentSource: {DeFiActions.Source}?,
        pushToDrawDownSink: Bool
    ): @PositionWrapper {
        let poolCap = self.account.storage.load<Capability<auth(FlowALPv1.EParticipant, FlowALPv1.EPosition) &FlowALPv1.Pool>>(
            from: FlowALPv1.PoolCapStoragePath
        ) ?? panic("Missing pool capability")

        let poolRef = poolCap.borrow() ?? panic("Invalid Pool Cap")

        let pid = poolRef.createPosition(
                funds: <-collateral,
                issuanceSink: issuanceSink,
                repaymentSource: repaymentSource,
                pushToDrawDownSink: pushToDrawDownSink
            )
        let position = FlowALPv1.Position(id: pid, pool: poolCap)
        self.account.storage.save(poolCap, to: FlowALPv1.PoolCapStoragePath)
        return <- create PositionWrapper(
            position: position
        )
    }

    /// A simple resource encapsulating a FlowALPv1 Position
    access(all) resource PositionWrapper {

        access(self) let position: FlowALPv1.Position

        init(position: FlowALPv1.Position) {
            self.position = position
        }

        /// NOT SAFE FOR PRODUCTION
        ///
        /// Returns a reference to the wrapped Position
        access(all) fun borrowPosition(): &FlowALPv1.Position {
            return &self.position
        }

        /// NOT SAFE FOR PRODUCTION
        ///
        /// Returns a reference to the wrapped Position with EParticipant entitlement for deposits
        access(all) fun borrowPositionForDeposit(): auth(FlowALPv1.EParticipant) &FlowALPv1.Position {
            return &self.position
        }

        access(all) fun borrowPositionForWithdraw(): auth(FungibleToken.Withdraw) &FlowALPv1.Position {
            return &self.position
        }
    }

    init() {
        self.WrapperStoragePath = /storage/flowALPv1PositionWrapper
    }
}
