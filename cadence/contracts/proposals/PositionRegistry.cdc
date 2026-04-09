/// PositionRegistry — Proposed Module
///
/// PURPOSE: Centralize position lifecycle management (creation, balance tracking, health
/// parameters, queued deposits, locks) behind a dedicated resource interface.
///
/// PROBLEM SOLVED: Currently, `Pool` directly stores `@{UInt64: {InternalPosition}}` and
/// position lock/queue state lives in `PoolState`. This means the Pool resource intermixes
/// position management with reserves, fees, and liquidation. Extracting position storage
/// into its own module makes it clear what operations affect positions vs. global state.
///
/// KEY CHANGES:
/// - Position locks are part of the registry, not the flat PoolState.
/// - Position balance updates go through the registry's API, not through raw borrowBalance() refs.
/// - The registry provides PositionView construction, consolidating the logic that currently
///   lives in Pool.buildPositionView().
///
/// NOTE: This is an interface proposal. It does NOT compile or replace existing contracts.

access(all) contract PositionRegistry {

    /// Entitlement for position creation and balance mutations.
    access(all) entitlement EPositionMutation

    /// Entitlement for lock management.
    access(all) entitlement EPositionLock

    // --- Main Interface ---

    access(all) resource interface PositionRegistryInterface {

        // --- Position Lifecycle ---

        /// Creates a new internal position and returns its ID.
        access(EPositionMutation) fun createPosition(): UInt64

        /// Returns whether a position exists with the given ID.
        access(all) view fun positionExists(pid: UInt64): Bool

        /// Returns the token types for which a position has balances.
        access(all) view fun getPositionBalanceKeys(pid: UInt64): [Type]

        // --- Balance Management ---

        /// Returns the current internal balance for a position/token pair, or nil.
        access(all) view fun getBalance(pid: UInt64, tokenType: Type): AnyStruct?
        // NOTE: Returns AnyStruct here; in practice returns FlowALPModels.InternalBalance?

        /// Updates the balance for a position/token pair.
        ///
        /// This replaces the pattern of:
        /// ```
        /// position.borrowBalance(type)!.recordDeposit(amount, tokenState)
        /// ```
        ///
        /// Instead, the coordinator computes a BalanceEffect via TokenLedger, then calls:
        /// ```
        /// positionRegistry.setBalance(pid, type, effect.newScaledBalance, effect.newDirection)
        /// ```
        ///
        /// This makes it explicit that position balances and global token state are
        /// updated separately, through different modules.
        ///
        access(EPositionMutation) fun setBalance(
            pid: UInt64,
            tokenType: Type,
            scaledBalance: UFix128,
            direction: UInt8 // 0 = Credit, 1 = Debit
        )

        /// Returns a copy of all balances for a position.
        /// Used to construct PositionView for health calculations.
        access(all) fun copyBalances(pid: UInt64): AnyStruct
        // NOTE: Returns {Type: InternalBalance} in practice

        // --- Health Parameters ---

        /// Returns the position's target/min/max health parameters.
        access(all) view fun getHealthParams(pid: UInt64): HealthParams

        /// Sets the target health for a position.
        access(EPositionMutation) fun setTargetHealth(pid: UInt64, target: UFix128)

        /// Sets the minimum health for a position.
        access(EPositionMutation) fun setMinHealth(pid: UInt64, min: UFix128)

        /// Sets the maximum health for a position.
        access(EPositionMutation) fun setMaxHealth(pid: UInt64, max: UFix128)

        // --- Queued Deposits ---

        /// Deposits a vault into the position's queue for deferred processing.
        access(EPositionMutation) fun depositToQueue(
            pid: UInt64,
            type: Type,
            vault: @{FungibleToken.Vault}
        )

        /// Removes and returns the queued deposit for the given token type.
        access(EPositionMutation) fun removeQueuedDeposit(
            pid: UInt64,
            type: Type
        ): @{FungibleToken.Vault}?

        /// Returns the token types with queued deposits for a position.
        access(all) view fun getQueuedDepositKeys(pid: UInt64): [Type]

        /// Returns the number of queued deposit entries for a position.
        access(all) view fun getQueuedDepositsLength(pid: UInt64): Int

        // --- Sink / Source ---

        /// Sets the draw-down sink for a position.
        access(EPositionMutation) fun setDrawDownSink(pid: UInt64, sink: AnyStruct?)
        // NOTE: AnyStruct? stands in for {DeFiActions.Sink}? here

        /// Sets the top-up source for a position.
        access(EPositionMutation) fun setTopUpSource(pid: UInt64, source: AnyStruct?)
        // NOTE: AnyStruct? stands in for {DeFiActions.Source}? here

        // --- Position Locks ---

        /// Locks a position to prevent concurrent mutations.
        access(EPositionLock) fun lock(pid: UInt64)

        /// Unlocks a position.
        access(EPositionLock) fun unlock(pid: UInt64)

        /// Returns whether the position is currently locked.
        access(all) view fun isLocked(pid: UInt64): Bool

        // --- Update Queue ---

        /// Queues a position for asynchronous update (rebalance, queued deposit processing).
        access(EPositionMutation) fun queueForUpdate(pid: UInt64)

        /// Returns and removes the next position ID from the update queue.
        access(EPositionMutation) fun dequeueForUpdate(): UInt64?

        /// Returns the number of positions in the update queue.
        access(all) view fun updateQueueLength(): Int

        /// Returns whether the given position is already queued.
        access(all) view fun isQueued(pid: UInt64): Bool
    }

    // --- Supporting Types ---

    /// Immutable view of a position's health parameters.
    access(all) struct HealthParams {
        access(all) let target: UFix128
        access(all) let min: UFix128
        access(all) let max: UFix128

        init(target: UFix128, min: UFix128, max: UFix128) {
            self.target = target
            self.min = min
            self.max = max
        }
    }
}
