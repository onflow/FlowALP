import "FungibleToken"

import "DeFiActions"
import "FlowALP"

/// THIS CONTRACT IS NOT SAFE FOR PRODUCTION - FOR TEST USE ONLY
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
/// A simple contract enabling the persistent storage of a Position similar to a pattern expected for platforms
/// building on top of FlowALP's lending protocol
///
access(all) contract MockFlowALPConsumer {

    /// Canonical path for where the wrapper is to be stored
    access(all) let WrapperStoragePath: StoragePath

    /// Opens a FlowALP Position and returns a PositionWrapper containing that new position
    ///
    access(all)
    fun createPositionWrapper(
        collateral: @{FungibleToken.Vault},
        issuanceSink: {DeFiActions.Sink},
        repaymentSource: {DeFiActions.Source}?,
        pushToDrawDownSink: Bool
    ): @PositionWrapper {
        let poolCap = self.account.storage.load<Capability<auth(FlowALP.EParticipant, FlowALP.EPosition) &FlowALP.Pool>>(
            from: FlowALP.PoolCapStoragePath
        ) ?? panic("Missing pool capability")

        let poolRef = poolCap.borrow() ?? panic("Invalid Pool Cap")

        let pid = poolRef.createPosition(
                funds: <-collateral,
                issuanceSink: issuanceSink,
                repaymentSource: repaymentSource,
                pushToDrawDownSink: pushToDrawDownSink
            )
        let position = FlowALP.Position(id: pid, pool: poolCap)
        self.account.storage.save(poolCap, to: FlowALP.PoolCapStoragePath)
        return <- create PositionWrapper(
            position: position
        )
    }

    /// A simple resource encapsulating a FlowALP Position
    access(all) resource PositionWrapper {

        access(self) let position: FlowALP.Position

        init(position: FlowALP.Position) {
            self.position = position
        }

        /// NOT SAFE FOR PRODUCTION
        ///
        /// Returns a reference to the wrapped Position
        access(all) fun borrowPosition(): &FlowALP.Position {
            return &self.position
        }

        /// NOT SAFE FOR PRODUCTION
        ///
        /// Returns a reference to the wrapped Position with EParticipant entitlement for deposits
        access(all) fun borrowPositionForDeposit(): auth(FlowALP.EParticipant) &FlowALP.Position {
            return &self.position
        }

        access(all) fun borrowPositionForWithdraw(): auth(FungibleToken.Withdraw) &FlowALP.Position {
            return &self.position
        }
    }

    init() {
        self.WrapperStoragePath = /storage/flowALPPositionWrapper
    }
}
