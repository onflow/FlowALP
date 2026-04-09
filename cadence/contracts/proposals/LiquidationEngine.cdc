/// LiquidationEngine — Proposed Module
///
/// PURPOSE: Extract liquidation validation and execution coordination from the Pool into
/// a dedicated module. The current `manualLiquidation` method is ~90 lines of tightly
/// coupled logic mixing validation, price comparison, health computation, and vault
/// manipulation. Separating validation from execution makes the invariants auditable.
///
/// PROBLEM SOLVED:
///
/// 1. **Monolithic liquidation method**: `Pool.manualLiquidation()` validates health,
///    computes post-liquidation health, checks DEX prices, and executes the swap —
///    all in one function. An auditor must read all 90 lines to verify any single invariant.
///
/// 2. **Inline oracle/DEX interaction**: The liquidation method directly calls
///    `config.getPriceOracle().price(ofToken: ...)` and `config.getSwapperForLiquidation(...)`.
///    These external calls are mixed with core accounting logic.
///
/// SOLUTION: Split into validation (pure) and execution (effectful):
///
/// 1. `validateLiquidation()` — pure function that checks all invariants and returns a
///    `LiquidationPlan` struct describing the validated liquidation.
///
/// 2. The Pool coordinator executes the plan through ReserveVaultManager and PositionRegistry.
///
/// INVARIANTS (preserved from current implementation):
/// - Position must have health < 1.0
/// - Post-liquidation health must be ≤ liquidationTargetHF
/// - Seize amount ≤ position's collateral balance
/// - Repay amount ≤ position's debt balance
/// - Liquidation price must be better than DEX price
/// - DEX/oracle price deviation must be within configured threshold
///
/// NOTE: This is an interface proposal. It does NOT compile or replace existing contracts.

access(all) contract LiquidationEngine {

    // --- Types ---

    /// Immutable description of a validated liquidation, produced by `validateLiquidation()`.
    ///
    /// The coordinator executes this plan step-by-step:
    /// 1. Deposit repayment to reserves via `reserveManager.deposit(repayment)`
    /// 2. Record repayment in position via `positionRegistry` + `tokenLedger`
    /// 3. Record seizure in position via `positionRegistry` + `tokenLedger`
    /// 4. Withdraw seized collateral via `reserveManager.withdrawForLiquidation(...)`
    /// 5. Return seized collateral to liquidator
    ///
    access(all) struct LiquidationPlan {
        /// The position being liquidated
        access(all) let pid: UInt64
        /// The debt token type being repaid
        access(all) let debtType: Type
        /// The amount of debt being repaid
        access(all) let repayAmount: UFix64
        /// The collateral token type being seized
        access(all) let seizeType: Type
        /// The amount of collateral being seized
        access(all) let seizeAmount: UFix64
        /// The post-liquidation health factor
        access(all) let postHealth: UFix128

        init(
            pid: UInt64,
            debtType: Type,
            repayAmount: UFix64,
            seizeType: Type,
            seizeAmount: UFix64,
            postHealth: UFix128
        ) {
            self.pid = pid
            self.debtType = debtType
            self.repayAmount = repayAmount
            self.seizeType = seizeType
            self.seizeAmount = seizeAmount
            self.postHealth = postHealth
        }
    }

    /// Reason a liquidation was rejected.
    access(all) enum LiquidationError: UInt8 {
        /// Position health is ≥ 1.0 (not liquidatable)
        access(all) case PositionHealthy
        /// Seize amount exceeds position's collateral balance
        access(all) case SeizeExceedsCollateral
        /// Repay amount exceeds position's debt balance
        access(all) case RepayExceedsDebt
        /// Post-liquidation health would exceed target
        access(all) case ExceedsTargetHealth
        /// Liquidator's price is worse than DEX
        access(all) case WorseThanDex
        /// DEX/oracle price deviation exceeds threshold
        access(all) case DexOracleDeviation
    }

    /// Result of liquidation validation.
    access(all) struct LiquidationResult {
        /// The validated plan, if validation succeeded
        access(all) let plan: LiquidationPlan?
        /// The error, if validation failed
        access(all) let error: LiquidationError?

        init(plan: LiquidationPlan?, error: LiquidationError?) {
            self.plan = plan
            self.error = error
        }
    }

    // --- Input Types ---

    /// Oracle and DEX price data needed for liquidation validation.
    /// The coordinator gathers this and passes it to the engine, keeping
    /// the engine free of oracle/DEX dependencies.
    access(all) struct LiquidationPriceContext {
        /// Oracle price of the debt token ($/D)
        access(all) let debtOraclePrice: UFix64
        /// Oracle price of the collateral token ($/C)
        access(all) let collateralOraclePrice: UFix64
        /// DEX quote: how much collateral needed to get `repayAmount` debt tokens
        /// (the `inAmount` from quoteIn)
        access(all) let dexQuoteCollateralForRepay: UFix64
        /// Max allowed DEX/oracle deviation in basis points
        access(all) let maxDeviationBps: UInt16
        /// Target health factor after liquidation (from pool config)
        access(all) let liquidationTargetHF: UFix128

        init(
            debtOraclePrice: UFix64,
            collateralOraclePrice: UFix64,
            dexQuoteCollateralForRepay: UFix64,
            maxDeviationBps: UInt16,
            liquidationTargetHF: UFix128
        ) {
            self.debtOraclePrice = debtOraclePrice
            self.collateralOraclePrice = collateralOraclePrice
            self.dexQuoteCollateralForRepay = dexQuoteCollateralForRepay
            self.maxDeviationBps = maxDeviationBps
            self.liquidationTargetHF = liquidationTargetHF
        }
    }

    /// Position's balance context needed for liquidation validation.
    access(all) struct PositionContext {
        /// The position's current health factor
        access(all) let health: UFix128
        /// True balance of collateral token in the position
        access(all) let collateralBalance: UFix128
        /// True balance of debt token in the position
        access(all) let debtBalance: UFix128
        /// Current effective collateral (total $)
        access(all) let effectiveCollateral: UFix128
        /// Current effective debt (total $)
        access(all) let effectiveDebt: UFix128
        /// Collateral factor for the seized token
        access(all) let collateralFactor: UFix128
        /// Borrow factor for the debt token
        access(all) let borrowFactor: UFix128

        init(
            health: UFix128,
            collateralBalance: UFix128,
            debtBalance: UFix128,
            effectiveCollateral: UFix128,
            effectiveDebt: UFix128,
            collateralFactor: UFix128,
            borrowFactor: UFix128
        ) {
            self.health = health
            self.collateralBalance = collateralBalance
            self.debtBalance = debtBalance
            self.effectiveCollateral = effectiveCollateral
            self.effectiveDebt = effectiveDebt
            self.collateralFactor = collateralFactor
            self.borrowFactor = borrowFactor
        }
    }

    // --- Main Interface ---

    /// LiquidationEngineInterface provides pure validation of liquidation proposals.
    ///
    /// The engine does NOT hold any state or touch any vaults. It takes context structs
    /// and returns either a validated LiquidationPlan or a descriptive error.
    ///
    /// Usage in the Pool coordinator:
    /// ```
    /// // 1. Gather context
    /// let priceCtx = LiquidationPriceContext(...)
    /// let posCtx = PositionContext(...)
    ///
    /// // 2. Validate
    /// let result = liquidationEngine.validateLiquidation(
    ///     pid: pid, debtType: debtType, seizeType: seizeType,
    ///     seizeAmount: seizeAmount, repayAmount: repayAmount,
    ///     position: posCtx, prices: priceCtx
    /// )
    ///
    /// // 3. Execute if valid
    /// if let plan = result.plan {
    ///     reserveManager.deposit(from: <-repayment)
    ///     // ... record in position, withdraw collateral ...
    ///     let seized <- reserveManager.withdrawForLiquidation(plan.seizeType, plan.seizeAmount, plan.pid)
    ///     return <-seized
    /// } else {
    ///     panic("Liquidation rejected: \(result.error!)")
    /// }
    /// ```
    ///
    access(all) struct interface LiquidationEngineInterface {

        /// Validates a proposed liquidation and returns either a plan or an error.
        ///
        /// This is a PURE function — it reads only the provided parameters and
        /// performs no state mutations. All invariants from the current implementation
        /// are checked here.
        ///
        access(all) fun validateLiquidation(
            pid: UInt64,
            debtType: Type,
            seizeType: Type,
            seizeAmount: UFix64,
            repayAmount: UFix64,
            position: PositionContext,
            prices: LiquidationPriceContext
        ): LiquidationResult
    }
}
