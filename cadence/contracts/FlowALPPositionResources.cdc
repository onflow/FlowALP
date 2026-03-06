import "FungibleToken"

import "DeFiActionsUtils"
import "DeFiActions"
import "FlowALPMath"
import "FlowALPModels"

access(all) contract FlowALPPositionResources {

    /// Position
    ///
    /// A Position is a resource representing ownership of value deposited to the protocol.
    /// From a Position, a user can deposit and withdraw funds as well as construct DeFiActions components enabling
    /// value flows in and out of the Position from within the context of DeFiActions stacks.
    /// Unauthorized Position references allow depositing only, and are considered safe to publish.
    /// The FlowALPModels.EPositionAdmin entitlement protects sensitive withdrawal and configuration methods.
    ///
    /// Position resources are held in user accounts and provide access to one position (by pid).
    /// Clients are recommended to use PositionManager to manage access to Positions.
    ///
    access(all) resource Position {

        /// The unique ID of the Position used to track deposits and withdrawals to the Pool
        access(all) let id: UInt64

        /// An authorized Capability to the Pool for which this Position was opened.
        access(self) let pool: Capability<auth(FlowALPModels.EPosition) &{FlowALPModels.PositionPool}>

        init(
            id: UInt64,
            pool: Capability<auth(FlowALPModels.EPosition) &{FlowALPModels.PositionPool}>
        ) {
            pre {
                pool.check():
                    "Invalid Pool Capability provided - cannot construct Position"
            }
            self.id = id
            self.pool = pool
        }

        /// Returns the balances (both positive and negative) for all tokens in this position.
        access(all) fun getBalances(): [FlowALPModels.PositionBalance] {
            let pool = self.pool.borrow()!
            return pool.getPositionDetails(pid: self.id).balances
        }

        /// Returns the balance available for withdrawal of a given Vault type. If pullFromTopUpSource is true, the
        /// calculation will be made assuming the position is topped up if the withdrawal amount puts the Position
        /// below its min health. If pullFromTopUpSource is false, the calculation will return the balance currently
        /// available without topping up the position.
        access(all) fun availableBalance(type: Type, pullFromTopUpSource: Bool): UFix64 {
            let pool = self.pool.borrow()!
            return pool.availableBalance(pid: self.id, type: type, pullFromTopUpSource: pullFromTopUpSource)
        }

        /// Returns the current health of the position
        access(all) fun getHealth(): UFix128 {
            let pool = self.pool.borrow()!
            return pool.positionHealth(pid: self.id)
        }

        /// Returns the Position's target health (unitless ratio ≥ 1.0)
        access(all) fun getTargetHealth(): UFix64 {
            let pool = self.pool.borrow()!
            let pos = pool.borrowPosition(pid: self.id)
            return FlowALPMath.toUFix64Round(pos.getTargetHealth())
        }

        /// Sets the target health of the Position
        access(FlowALPModels.EPositionAdmin) fun setTargetHealth(targetHealth: UFix64) {
            let pool = self.pool.borrow()!
            let pos = pool.borrowPosition(pid: self.id)
            pos.setTargetHealth(UFix128(targetHealth))
        }

        /// Returns the minimum health of the Position
        access(all) fun getMinHealth(): UFix64 {
            let pool = self.pool.borrow()!
            let pos = pool.borrowPosition(pid: self.id)
            return FlowALPMath.toUFix64Round(pos.getMinHealth())
        }

        /// Sets the minimum health of the Position
        access(FlowALPModels.EPositionAdmin) fun setMinHealth(minHealth: UFix64) {
            let pool = self.pool.borrow()!
            let pos = pool.borrowPosition(pid: self.id)
            pos.setMinHealth(UFix128(minHealth))
        }

        /// Returns the maximum health of the Position
        access(all) fun getMaxHealth(): UFix64 {
            let pool = self.pool.borrow()!
            let pos = pool.borrowPosition(pid: self.id)
            return FlowALPMath.toUFix64Round(pos.getMaxHealth())
        }

        /// Sets the maximum health of the position
        access(FlowALPModels.EPositionAdmin) fun setMaxHealth(maxHealth: UFix64) {
            let pool = self.pool.borrow()!
            let pos = pool.borrowPosition(pid: self.id)
            pos.setMaxHealth(UFix128(maxHealth))
        }

        /// Returns the maximum amount of the given token type that could be deposited into this position
        access(all) fun getDepositCapacity(type: Type): UFix64 {
            // There's no limit on deposits from the position's perspective
            return UFix64.max
        }

        /// Deposits funds to the Position without immediately pushing to the drawDownSink if the deposit puts the Position above its maximum health.
        /// NOTE: Anyone is allowed to deposit to any position.
        access(all) fun deposit(from: @{FungibleToken.Vault}) {
            self.depositAndPush(
                from: <-from,
                pushToDrawDownSink: false
            )
        }

        /// Deposits funds to the Position enabling the caller to configure whether excess value
        /// should be pushed to the drawDownSink if the deposit puts the Position above its maximum health
        /// NOTE: Anyone is allowed to deposit to any position.
        access(all) fun depositAndPush(
            from: @{FungibleToken.Vault},
            pushToDrawDownSink: Bool
        ) {
            let pool = self.pool.borrow()!
            pool.depositAndPush(
                pid: self.id,
                from: <-from,
                pushToDrawDownSink: pushToDrawDownSink
            )
        }

        /// Withdraws funds from the Position without pulling from the topUpSource
        /// if the withdrawal puts the Position below its minimum health
        access(FungibleToken.Withdraw) fun withdraw(type: Type, amount: UFix64): @{FungibleToken.Vault} {
            return <- self.withdrawAndPull(
                type: type,
                amount: amount,
                pullFromTopUpSource: false
            )
        }

        /// Withdraws funds from the Position enabling the caller to configure whether insufficient value
        /// should be pulled from the topUpSource if the withdrawal puts the Position below its minimum health
        access(FungibleToken.Withdraw) fun withdrawAndPull(
            type: Type,
            amount: UFix64,
            pullFromTopUpSource: Bool
        ): @{FungibleToken.Vault} {
            let pool = self.pool.borrow()!
            return <- pool.withdrawAndPull(
                pid: self.id,
                type: type,
                amount: amount,
                pullFromTopUpSource: pullFromTopUpSource
            )
        }

        /// Returns a new Sink for the given token type that will accept deposits of that token
        /// and update the position's collateral and/or debt accordingly.
        ///
        /// Note that calling this method multiple times will create multiple sinks,
        /// each of which will continue to work regardless of how many other sinks have been created.
        access(all) fun createSink(type: Type): {DeFiActions.Sink} {
            // create enhanced sink with pushToDrawDownSink option
            return self.createSinkWithOptions(
                type: type,
                pushToDrawDownSink: false
            )
        }

        /// Returns a new Sink for the given token type and pushToDrawDownSink option
        /// that will accept deposits of that token and update the position's collateral and/or debt accordingly.
        ///
        /// Note that calling this method multiple times will create multiple sinks,
        /// each of which will continue to work regardless of how many other sinks have been created.
        access(all) fun createSinkWithOptions(
            type: Type,
            pushToDrawDownSink: Bool
        ): {DeFiActions.Sink} {
            let pool = self.pool.borrow()!
            return PositionSink(
                id: self.id,
                pool: self.pool,
                type: type,
                pushToDrawDownSink: pushToDrawDownSink
            )
        }

        /// Returns a new Source for the given token type that will service withdrawals of that token
        /// and update the position's collateral and/or debt accordingly.
        ///
        /// Note that calling this method multiple times will create multiple sources,
        /// each of which will continue to work regardless of how many other sources have been created.
        access(FungibleToken.Withdraw) fun createSource(type: Type): {DeFiActions.Source} {
            // Create source with pullFromTopUpSource = false
            return self.createSourceWithOptions(
                type: type,
                pullFromTopUpSource: false
            )
        }

        /// Returns a new Source for the given token type and pullFromTopUpSource option
        /// that will service withdrawals of that token and update the position's collateral and/or debt accordingly.
        ///
        /// Note that calling this method multiple times will create multiple sources,
        /// each of which will continue to work regardless of how many other sources have been created.
        access(FungibleToken.Withdraw) fun createSourceWithOptions(
            type: Type,
            pullFromTopUpSource: Bool
        ): {DeFiActions.Source} {
            let pool = self.pool.borrow()!
            return PositionSource(
                id: self.id,
                pool: self.pool,
                type: type,
                pullFromTopUpSource: pullFromTopUpSource
            )
        }

        /// Provides a sink to the Position that will have tokens proactively pushed into it
        /// when the position has excess collateral.
        /// (Remember that sinks do NOT have to accept all tokens provided to them;
        /// the sink can choose to accept only some (or none) of the tokens provided,
        /// leaving the position overcollateralized).
        ///
        /// Each position can have only one sink, and the sink must accept the default token type
        /// configured for the pool. Providing a new sink will replace the existing sink.
        ///
        /// Pass nil to configure the position to not push tokens when the Position exceeds its maximum health.
        access(FlowALPModels.EPositionAdmin) fun provideSink(sink: {DeFiActions.Sink}?) {
            let pool = self.pool.borrow()!
            pool.lockPosition(self.id)
            let pos = pool.borrowPosition(pid: self.id)
            pos.setDrawDownSink(sink)
            pool.unlockPosition(self.id)
        }

        /// Provides a source to the Position that will have tokens proactively pulled from it
        /// when the position has insufficient collateral.
        /// If the source can cover the position's debt, the position will not be liquidated.
        ///
        /// Each position can have only one source, and the source must accept the default token type
        /// configured for the pool. Providing a new source will replace the existing source.
        ///
        /// Pass nil to configure the position to not pull tokens.
        access(FlowALPModels.EPositionAdmin) fun provideSource(source: {DeFiActions.Source}?) {
            let pool = self.pool.borrow()!
            pool.lockPosition(self.id)
            let pos = pool.borrowPosition(pid: self.id)
            pos.setTopUpSource(source)
            pool.unlockPosition(self.id)
        }

        /// Rebalances the position to the target health value, if the position is under- or over-collateralized,
        /// as defined by the position-specific min/max health thresholds.
        /// If force=true, the position will be rebalanced regardless of its current health.
        ///
        /// When rebalancing, funds are withdrawn from the position's topUpSource or deposited to its drawDownSink.
        /// Rebalancing is done on a best effort basis (even when force=true). If the position has no sink/source,
        /// of either cannot accept/provide sufficient funds for rebalancing, the rebalance will still occur but will
        /// not cause the position to reach its target health.
        access(FlowALPModels.EPosition | FlowALPModels.ERebalance) fun rebalance(force: Bool) {
            let pool = self.pool.borrow()!
            pool.rebalancePosition(pid: self.id, force: force)
        }
    }

    /// PositionManager
    ///
    /// A collection resource that manages multiple Position resources for an account.
    /// This allows users to have multiple positions while using a single, constant storage path.
    ///
    access(all) resource PositionManager {

        /// Dictionary storing all positions owned by this manager, keyed by position ID
        access(self) let positions: @{UInt64: Position}

        init() {
            self.positions <- {}
        }

        /// Adds a new position to the manager.
        access(FlowALPModels.EPositionAdmin) fun addPosition(position: @Position) {
            let pid = position.id
            let old <- self.positions[pid] <- position
            if old != nil {
                panic("Cannot add position with same pid (\(pid)) as existing position: must explicitly remove existing position first")
            }
            destroy old
        }

        /// Removes and returns a position from the manager.
        access(FlowALPModels.EPositionAdmin) fun removePosition(pid: UInt64): @Position {
            if let position <- self.positions.remove(key: pid) {
                return <-position
            }
            panic("Position with pid=\(pid) not found in PositionManager")
        }

        /// Internal method that returns a reference to a position authorized with all entitlements.
        /// Callers who wish to provide a partially authorized reference can downcast the result as needed.
        access(FlowALPModels.EPositionAdmin) fun borrowAuthorizedPosition(pid: UInt64): auth(FungibleToken.Withdraw, FlowALPModels.EPositionAdmin) &Position {
            return (&self.positions[pid] as auth(FungibleToken.Withdraw, FlowALPModels.EPositionAdmin) &Position?)
                ?? panic("Position with pid=\(pid) not found in PositionManager")
        }

        /// Returns a public reference to a position with no entitlements.
        access(all) fun borrowPosition(pid: UInt64): &Position {
            return (&self.positions[pid] as &Position?)
                ?? panic("Position with pid=\(pid) not found in PositionManager")
        }

        /// Returns the IDs of all positions in this manager
        access(all) fun getPositionIDs(): [UInt64] {
            return self.positions.keys
        }
    }

    /// Creates and returns a new Position resource.
    access(all) fun createPosition(
        id: UInt64,
        pool: Capability<auth(FlowALPModels.EPosition) &{FlowALPModels.PositionPool}>
    ): @Position {
        return <- create Position(id: id, pool: pool)
    }

    /// Creates and returns a new PositionManager resource
    access(all) fun createPositionManager(): @PositionManager {
        return <- create PositionManager()
    }

    /// PositionSink
    ///
    /// A DeFiActions connector enabling deposits to a Position from within a DeFiActions stack.
    /// This Sink is intended to be constructed from a Position object.
    ///
    access(all) struct PositionSink: DeFiActions.Sink {

        /// An optional DeFiActions.UniqueIdentifier that identifies this Sink with the DeFiActions stack its a part of
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        /// An authorized Capability on the Pool for which the related Position is in
        access(self) let pool: Capability<auth(FlowALPModels.EPosition) &{FlowALPModels.PositionPool}>

        /// The ID of the position in the Pool
        access(self) let positionID: UInt64

        /// The Type of Vault this Sink accepts
        access(self) let type: Type

        /// Whether deposits through this Sink to the Position should push available value to the Position's
        /// drawDownSink
        access(self) let pushToDrawDownSink: Bool

        init(
            id: UInt64,
            pool: Capability<auth(FlowALPModels.EPosition) &{FlowALPModels.PositionPool}>,
            type: Type,
            pushToDrawDownSink: Bool
        ) {
            self.uniqueID = nil
            self.positionID = id
            self.pool = pool
            self.type = type
            self.pushToDrawDownSink = pushToDrawDownSink
        }

        /// Returns the Type of Vault this Sink accepts on deposits
        access(all) view fun getSinkType(): Type {
            return self.type
        }

        /// Returns the minimum capacity this Sink can accept as deposits
        access(all) fun minimumCapacity(): UFix64 {
            return self.pool.check() ? UFix64.max : 0.0
        }

        /// Deposits the funds from the provided Vault reference to the related Position
        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            if let pool = self.pool.borrow() {
                pool.depositAndPush(
                    pid: self.positionID,
                    from: <-from.withdraw(amount: from.balance),
                    pushToDrawDownSink: self.pushToDrawDownSink
                )
            }
        }

        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
                innerComponents: []
            )
        }

        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }

        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) {
            self.uniqueID = id
        }
    }

    /// PositionSource
    ///
    /// A DeFiActions connector enabling withdrawals from a Position from within a DeFiActions stack.
    /// This Source is intended to be constructed from a Position object.
    ///
    access(all) struct PositionSource: DeFiActions.Source {

        /// An optional DeFiActions.UniqueIdentifier that identifies this Sink with the DeFiActions stack its a part of
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        /// An authorized Capability on the Pool for which the related Position is in
        access(self) let pool: Capability<auth(FlowALPModels.EPosition) &{FlowALPModels.PositionPool}>

        /// The ID of the position in the Pool
        access(self) let positionID: UInt64

        /// The Type of Vault this Sink provides
        access(self) let type: Type

        /// Whether withdrawals through this Sink from the Position should pull value from the Position's topUpSource
        /// in the event the withdrawal puts the position under its target health
        access(self) let pullFromTopUpSource: Bool

        init(
            id: UInt64,
            pool: Capability<auth(FlowALPModels.EPosition) &{FlowALPModels.PositionPool}>,
            type: Type,
            pullFromTopUpSource: Bool
        ) {
            self.uniqueID = nil
            self.positionID = id
            self.pool = pool
            self.type = type
            self.pullFromTopUpSource = pullFromTopUpSource
        }

        /// Returns the Type of Vault this Source provides on withdrawals
        access(all) view fun getSourceType(): Type {
            return self.type
        }

        /// Returns the minimum available this Source can provide on withdrawal
        access(all) fun minimumAvailable(): UFix64 {
            if !self.pool.check() {
                return 0.0
            }

            let pool = self.pool.borrow()!
            return pool.availableBalance(
                pid: self.positionID,
                type: self.type,
                pullFromTopUpSource: self.pullFromTopUpSource
            )
        }

        /// Withdraws up to the max amount as the sourceType Vault
        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            if !self.pool.check() {
                return <- DeFiActionsUtils.getEmptyVault(self.type)
            }

            let pool = self.pool.borrow()!
            let available = pool.availableBalance(
                pid: self.positionID,
                type: self.type,
                pullFromTopUpSource: self.pullFromTopUpSource
            )
            let withdrawAmount = (available > maxAmount) ? maxAmount : available
            if withdrawAmount > 0.0 {
                return <- pool.withdrawAndPull(
                    pid: self.positionID,
                    type: self.type,
                    amount: withdrawAmount,
                    pullFromTopUpSource: self.pullFromTopUpSource
                )
            } else {
                // Create an empty vault - this is a limitation we need to handle properly
                return <- DeFiActionsUtils.getEmptyVault(self.type)
            }
        }

        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
                innerComponents: []
            )
        }

        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }

        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) {
            self.uniqueID = id
        }
    }
}
