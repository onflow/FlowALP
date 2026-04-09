/// FeeCollector — Proposed Module
///
/// PURPOSE: Extract insurance and stability fee logic from the Pool into a dedicated module
/// with a clear, auditable API.
///
/// PROBLEM SOLVED: Currently, `_collectInsurance` and `_collectStability` are private methods
/// on the Pool resource. They directly borrow reserve vaults, compute fee amounts based on
/// interest income, perform DEX swaps (for insurance), and deposit into insurance/stability
/// funds. This interleaving means:
///
/// 1. Fee collection code has raw access to reserve vaults (same reference as user withdrawals).
/// 2. Fee calculation and reserve mutation are in the same function, making it hard to test
///    the math independently.
/// 3. A bug in DEX swap interaction during insurance collection could affect reserve solvency.
///
/// SOLUTION: Separate fee *calculation* from fee *execution*.
///
/// The FeeCollector computes how much to collect and returns a `FeeAction` describing the
/// required operations. The Pool coordinator then executes the action through the
/// ReserveVaultManager's purpose-specific `withdrawForInsurance` / `withdrawForStability`
/// functions. This separation means:
///
/// - Fee math can be unit tested without touching vaults.
/// - Reserve withdrawals go through the ReserveVaultManager's auditable API.
/// - DEX swap failures don't affect the FeeCollector's state.
///
/// NOTE: This is an interface proposal. It does NOT compile or replace existing contracts.

access(all) contract FeeCollector {

    /// Entitlement for computing and executing fee collection.
    access(all) entitlement EFeeCollection

    // --- Fee Action Types ---

    /// Describes an insurance fee collection action to be executed by the coordinator.
    ///
    /// The FeeCollector computes this; the coordinator executes it by:
    /// 1. Calling `reserveManager.withdrawForInsurance(type, amount)`
    /// 2. Swapping the withdrawn tokens to MOET via the swapper
    /// 3. Depositing the MOET into the insurance fund
    ///
    access(all) struct InsuranceFeeAction {
        /// The token type to withdraw from reserves
        access(all) let tokenType: Type
        /// The amount to withdraw (denominated in the token type)
        access(all) let amount: UFix64
        /// The timestamp to record as the collection time
        access(all) let collectionTime: UFix64

        init(tokenType: Type, amount: UFix64, collectionTime: UFix64) {
            self.tokenType = tokenType
            self.amount = amount
            self.collectionTime = collectionTime
        }
    }

    /// Describes a stability fee collection action to be executed by the coordinator.
    ///
    /// The FeeCollector computes this; the coordinator executes it by:
    /// 1. Calling `reserveManager.withdrawForStability(type, amount)`
    /// 2. Depositing the withdrawn tokens into the stability fund
    ///
    access(all) struct StabilityFeeAction {
        /// The token type to withdraw from reserves
        access(all) let tokenType: Type
        /// The amount to withdraw (denominated in the token type)
        access(all) let amount: UFix64
        /// The timestamp to record as the collection time
        access(all) let collectionTime: UFix64

        init(tokenType: Type, amount: UFix64, collectionTime: UFix64) {
            self.tokenType = tokenType
            self.amount = amount
            self.collectionTime = collectionTime
        }
    }

    // --- Main Interface ---

    /// FeeCollectorInterface computes fee amounts without touching reserves.
    ///
    /// Usage pattern in the Pool coordinator:
    /// ```
    /// // 1. Compute what needs to be collected
    /// let insuranceAction = feeCollector.computeInsuranceFee(tokenType, tokenState, reserveBalance)
    ///
    /// // 2. Execute through the reserve manager (separate entitlement)
    /// if let action = insuranceAction {
    ///     let vault <- reserveManager.withdrawForInsurance(action.tokenType, action.amount)
    ///     let moet <- swapper.swap(vault)
    ///     insuranceFund.deposit(from: <-moet)
    ///     feeCollector.recordInsuranceCollection(action)
    /// }
    /// ```
    ///
    access(all) resource interface FeeCollectorInterface {

        // --- Insurance Fee ---

        /// Computes the insurance fee to collect for the given token type.
        ///
        /// Returns nil if:
        /// - Insurance rate is 0
        /// - No time has elapsed since last collection
        /// - Computed amount rounds to 0
        /// - Reserve balance is insufficient to cover the full fee
        ///
        /// @param tokenType: The token type to compute insurance for
        /// @param insuranceRate: The insurance rate for this token (from TokenState)
        /// @param totalDebitBalance: The total debit balance for this token (from TokenState)
        /// @param currentDebitRate: The per-second debit rate (from TokenState)
        /// @param lastCollectionTime: The timestamp of the last insurance collection
        /// @param reserveBalance: The current reserve balance (for sufficiency check)
        /// @return An InsuranceFeeAction if collection should proceed, nil otherwise
        access(EFeeCollection) fun computeInsuranceFee(
            tokenType: Type,
            insuranceRate: UFix64,
            totalDebitBalance: UFix128,
            currentDebitRate: UFix128,
            lastCollectionTime: UFix64,
            reserveBalance: UFix64
        ): InsuranceFeeAction?

        /// Records that an insurance fee was collected (updates last collection timestamp).
        /// Called by the coordinator after successfully executing the InsuranceFeeAction.
        access(EFeeCollection) fun recordInsuranceCollection(
            tokenType: Type,
            collectionTime: UFix64
        )

        // --- Stability Fee ---

        /// Computes the stability fee to collect for the given token type.
        /// Same pattern as insurance: returns nil if nothing to collect.
        access(EFeeCollection) fun computeStabilityFee(
            tokenType: Type,
            stabilityFeeRate: UFix64,
            totalDebitBalance: UFix128,
            currentDebitRate: UFix128,
            lastCollectionTime: UFix64,
            reserveBalance: UFix64
        ): StabilityFeeAction?

        /// Records that a stability fee was collected.
        access(EFeeCollection) fun recordStabilityCollection(
            tokenType: Type,
            collectionTime: UFix64
        )

        // --- Insurance Fund ---

        /// Returns the current insurance fund (MOET) balance.
        access(all) view fun insuranceFundBalance(): UFix64

        /// Deposits MOET into the insurance fund.
        /// Called by the coordinator after swapping the insurance fee to MOET.
        access(EFeeCollection) fun depositToInsuranceFund(from: @AnyResource)
        // NOTE: @AnyResource stands in for @MOET.Vault; can't import MOET here.

        // --- Stability Fund ---

        /// Returns the stability fund balance for a given token type.
        access(all) view fun stabilityFundBalance(tokenType: Type): UFix64

        /// Deposits tokens into the stability fund for the given type.
        access(EFeeCollection) fun depositToStabilityFund(
            tokenType: Type,
            from: @AnyResource
        )
        // NOTE: @AnyResource stands in for @{FungibleToken.Vault}

        /// Withdraws from the stability fund (governance operation).
        access(EFeeCollection) fun withdrawFromStabilityFund(
            tokenType: Type,
            amount: UFix64
        ): @AnyResource
        // NOTE: @AnyResource stands in for @{FungibleToken.Vault}
    }
}
