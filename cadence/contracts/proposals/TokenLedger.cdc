/// TokenLedger — Proposed Module
///
/// PURPOSE: Centralize per-token accounting (interest indices, total balances, rate curves,
/// deposit capacity) and replace the side-effect-heavy `InternalBalance.recordDeposit/Withdrawal`
/// pattern with explicit effect objects.
///
/// PROBLEMS SOLVED:
///
/// 1. **Hidden side effects**: Currently, `InternalBalance.recordDeposit(amount, tokenState)`
///    directly mutates `tokenState` (increases/decreases global credit/debit totals, triggers
///    interest rate recalculation). The caller doesn't see this in the function signature.
///    This proposal makes effects explicit: `computeDepositEffect()` returns a struct describing
///    what would change, and `applyEffect()` applies it. The data flow is visible.
///
/// 2. **Risk factor fragmentation**: Collateral factors and borrow factors live in `PoolConfig`,
///    while interest rates, deposit limits, and everything else live in `TokenState`. Building a
///    `TokenSnapshot` requires pulling from two sources. This proposal colocates risk factors
///    with the token state.
///
/// 3. **Snapshot construction duplication**: `TokenSnapshot` is built in 4+ places with slightly
///    different code. This proposal provides a single `snapshot()` factory.
///
/// NOTE: This is an interface proposal. It does NOT compile or replace existing contracts.

import "FlowALPInterestRates"

access(all) contract TokenLedger {

    /// Entitlement for modifying token accounting state (balances, indices).
    access(all) entitlement ETokenAccounting

    /// Entitlement for governance changes (curves, risk factors, deposit params).
    access(all) entitlement ETokenGovernance

    // --- Effect Types ---

    /// Describes the outcome of a deposit or withdrawal on a single token's global accounting.
    ///
    /// Instead of `InternalBalance.recordDeposit()` directly mutating `TokenState`, the
    /// TokenLedger computes this struct and the coordinator applies it. This makes the
    /// data flow auditable: you can see exactly what changes before they happen.
    ///
    access(all) struct BalanceEffect {
        /// The token type this effect applies to
        access(all) let tokenType: Type

        /// The new scaled balance for the position (replaces old balance)
        access(all) let newScaledBalance: UFix128
        /// The new direction for the position's balance
        access(all) let newDirection: UInt8 // 0 = Credit, 1 = Debit

        /// Change to the token's global credit total (positive = increase, zero = no change).
        /// Only one of creditDelta/debitDelta can be non-zero.
        access(all) let creditDeltaIncrease: UFix128
        access(all) let creditDeltaDecrease: UFix128

        /// Change to the token's global debit total
        access(all) let debitDeltaIncrease: UFix128
        access(all) let debitDeltaDecrease: UFix128

        init(
            tokenType: Type,
            newScaledBalance: UFix128,
            newDirection: UInt8,
            creditDeltaIncrease: UFix128,
            creditDeltaDecrease: UFix128,
            debitDeltaIncrease: UFix128,
            debitDeltaDecrease: UFix128
        ) {
            self.tokenType = tokenType
            self.newScaledBalance = newScaledBalance
            self.newDirection = newDirection
            self.creditDeltaIncrease = creditDeltaIncrease
            self.creditDeltaDecrease = creditDeltaDecrease
            self.debitDeltaIncrease = debitDeltaIncrease
            self.debitDeltaDecrease = debitDeltaDecrease
        }
    }

    // --- Token Configuration (colocated risk factors) ---

    /// Extended TokenState that includes risk parameters.
    ///
    /// Currently, `collateralFactor` and `borrowFactor` live in `PoolConfig` as separate
    /// `{Type: UFix64}` maps. This couples `TokenSnapshot` construction to two data sources.
    ///
    /// By colocating risk factors here, building a snapshot requires only one source per token.
    ///
    access(all) struct interface TokenConfig {

        // --- From existing TokenState ---
        access(all) view fun getTokenType(): Type
        access(all) view fun getLastUpdate(): UFix64
        access(all) view fun getTotalCreditBalance(): UFix128
        access(all) view fun getTotalDebitBalance(): UFix128
        access(all) view fun getCreditInterestIndex(): UFix128
        access(all) view fun getDebitInterestIndex(): UFix128
        access(all) view fun getCurrentCreditRate(): UFix128
        access(all) view fun getCurrentDebitRate(): UFix128
        access(all) view fun getInterestCurve(): {FlowALPInterestRates.InterestCurve}

        // --- Colocated risk factors (moved from PoolConfig) ---
        access(all) view fun getCollateralFactor(): UFix128
        access(all) view fun getBorrowFactor(): UFix128

        // --- Deposit capacity (unchanged) ---
        access(all) view fun getDepositCapacity(): UFix64
        access(all) view fun getDepositCapacityCap(): UFix64
        access(all) view fun getDepositRate(): UFix64

        // --- Fee rates (unchanged) ---
        access(all) view fun getInsuranceRate(): UFix64
        access(all) view fun getStabilityFeeRate(): UFix64
    }

    // --- Main Interface ---

    /// TokenLedgerInterface defines the public API for per-token accounting.
    ///
    /// This replaces the `TokenState` portion of `PoolState` and the scattered
    /// `TokenSnapshot` construction logic throughout the Pool resource.
    ///
    access(all) resource interface TokenLedgerInterface {

        // --- Snapshot Factory (centralizes 4+ duplicated code paths) ---

        /// Builds an immutable TokenSnapshot for the given token type and oracle price.
        ///
        /// Before this proposal, TokenSnapshot construction was duplicated in:
        /// - `Pool.buildTokenSnapshot()` (line 721)
        /// - `Pool.buildPositionView()` (line 2061)
        /// - `Pool.availableBalance()` (line 416)
        /// - Contract-level `maxWithdraw()` (line 62)
        ///
        /// Each built the snapshot slightly differently (some used `config.getCollateralFactor`,
        /// some created `RiskParamsImplv1` inline). This factory is the single source of truth.
        ///
        /// @param type: The token type
        /// @param oraclePrice: Current oracle price in UFix64 (converted to UFix128 internally)
        /// @return An immutable TokenSnapshot ready for health computations
        access(all) fun snapshot(type: Type, oraclePrice: UFix64): AnyStruct
        // NOTE: Returns AnyStruct here because we can't import FlowALPModels.TokenSnapshot
        //       in this proposal file. In practice, this returns FlowALPModels.TokenSnapshot.

        // --- Effect Computation (replaces side-effect-heavy InternalBalance methods) ---

        /// Computes the effect of depositing `amount` into a position that currently
        /// has `currentScaledBalance` for the given token.
        ///
        /// This replaces `InternalBalance.recordDeposit(amount, tokenState)`.
        ///
        /// The returned BalanceEffect describes:
        /// - The new scaled balance for the position
        /// - The deltas to apply to global credit/debit totals
        ///
        /// The caller (Pool coordinator) then applies these effects:
        /// ```
        /// let effect = ledger.computeDepositEffect(...)
        /// ledger.applyGlobalEffect(effect)
        /// positionRegistry.setBalance(pid, type, effect.newScaledBalance, effect.newDirection)
        /// ```
        ///
        access(ETokenAccounting) fun computeDepositEffect(
            tokenType: Type,
            currentScaledBalance: UFix128,
            currentDirection: UInt8,
            amount: UFix128
        ): BalanceEffect

        /// Computes the effect of withdrawing `amount` from a position.
        /// Mirrors `computeDepositEffect` for the withdrawal case.
        access(ETokenAccounting) fun computeWithdrawalEffect(
            tokenType: Type,
            currentScaledBalance: UFix128,
            currentDirection: UInt8,
            amount: UFix128
        ): BalanceEffect

        /// Applies the global accounting changes from a BalanceEffect.
        /// Updates total credit/debit balances and recalculates interest rates.
        access(ETokenAccounting) fun applyGlobalEffect(_ effect: BalanceEffect)

        // --- Time-Based Updates (unchanged logic, cleaner interface) ---

        /// Updates interest indices and deposit capacity for elapsed time.
        /// Idempotent within a single block.
        access(ETokenAccounting) fun updateForTime(tokenType: Type)

        // --- Governance (moved from Pool + PoolConfig) ---

        /// Sets risk parameters for a token type.
        /// Replaces `PoolConfig.setCollateralFactor` + `PoolConfig.setBorrowFactor`.
        access(ETokenGovernance) fun setRiskParams(
            tokenType: Type,
            collateralFactor: UFix128,
            borrowFactor: UFix128
        )

        /// Sets the interest curve for a token type.
        /// Compounds accrued interest at the old rate before switching.
        access(ETokenGovernance) fun setInterestCurve(
            tokenType: Type,
            curve: {FlowALPInterestRates.InterestCurve}
        )

        // --- Read-only ---

        /// Returns the supported token types.
        access(all) view fun getSupportedTokens(): [Type]

        /// Returns whether the given token type is supported.
        access(all) view fun isTokenSupported(tokenType: Type): Bool

        /// Returns a copy of the token config for the given type, or nil.
        access(all) view fun getTokenConfig(tokenType: Type): {TokenConfig}?
    }
}
