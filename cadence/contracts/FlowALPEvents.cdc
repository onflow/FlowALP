/// FlowALPEvents
///
/// Centralizes all protocol event definitions for the FlowALP lending protocol.
/// Events are emitted via access(account)-scoped functions, ensuring only
/// co-deployed protocol contracts can emit them.
access(all) contract FlowALPEvents {

    /// Emitted when a new lending position is opened within a pool.
    ///
    /// @param pid the unique identifier of the newly created position
    /// @param poolUUID the UUID of the pool in which the position was opened
    access(all) event Opened(
        pid: UInt64,
        poolUUID: UInt64
    )

    /// Emitted when tokens are deposited into an existing position.
    ///
    /// @param pid the position identifier receiving the deposit
    /// @param poolUUID the UUID of the pool containing the position
    /// @param vaultType the Cadence type of the deposited fungible token vault
    /// @param amount the quantity of tokens deposited
    /// @param depositedUUID the UUID of the deposited vault resource
    access(all) event Deposited(
        pid: UInt64,
        poolUUID: UInt64,
        vaultType: Type,
        amount: UFix64,
        depositedUUID: UInt64
    )

    /// Emitted when tokens are withdrawn from an existing position.
    ///
    /// @param pid the position identifier from which tokens are withdrawn
    /// @param poolUUID the UUID of the pool containing the position
    /// @param vaultType the Cadence type of the withdrawn fungible token vault
    /// @param amount the quantity of tokens withdrawn
    /// @param withdrawnUUID the UUID of the withdrawn vault resource
    access(all) event Withdrawn(
        pid: UInt64,
        poolUUID: UInt64,
        vaultType: Type,
        amount: UFix64,
        withdrawnUUID: UInt64
    )

    /// Emitted when a position is automatically rebalanced toward its target health factor.
    /// Rebalancing occurs when a position drifts above or below its configured health thresholds.
    ///
    /// @param pid the position identifier being rebalanced
    /// @param poolUUID the UUID of the pool containing the position
    /// @param atHealth the position's health factor at the time of rebalancing
    /// @param amount the quantity of tokens moved during the rebalance
    /// @param fromUnder true if the position was undercollateralized (collateral added), false if overcollateralized (collateral removed)
    access(all) event Rebalanced(
        pid: UInt64,
        poolUUID: UInt64,
        atHealth: UFix128,
        amount: UFix64,
        fromUnder: Bool
    )

    /// Emitted when the pool is paused, temporarily disabling all user actions
    /// (deposits, withdrawals, and liquidations).
    ///
    /// @param poolUUID the UUID of the paused pool
    access(all) event PoolPaused(
        poolUUID: UInt64
    )

    /// Emitted when the pool is unpaused, re-enabling user actions after a warmup period.
    ///
    /// @param poolUUID the UUID of the unpaused pool
    /// @param warmupEndsAt the Unix timestamp (seconds) at which the warmup period ends and full functionality resumes
    access(all) event PoolUnpaused(
        poolUUID: UInt64,
        warmupEndsAt: UInt64
    )

    /// Emitted when a manual liquidation is executed against an unhealthy position.
    /// A liquidator repays part of the position's debt and seizes discounted collateral.
    ///
    /// @param pid the position identifier being liquidated
    /// @param poolUUID the UUID of the pool containing the position
    /// @param debtType the type identifier string of the debt token being repaid
    /// @param repayAmount the quantity of debt tokens repaid by the liquidator
    /// @param seizeType the type identifier string of the collateral token seized
    /// @param seizeAmount the quantity of collateral tokens seized by the liquidator
    /// @param newHF the position's health factor after the liquidation
    access(all) event LiquidationExecuted(
        pid: UInt64,
        poolUUID: UInt64,
        debtType: String,
        repayAmount: UFix64,
        seizeType: String,
        seizeAmount: UFix64,
        newHF: UFix128
    )

    /// Emitted when a liquidation is executed via a DEX swap rather than a direct liquidator offer.
    /// NOTE: Not currently used.
    ///
    /// @param pid the position identifier being liquidated
    /// @param poolUUID the UUID of the pool containing the position
    /// @param seizeType the type identifier string of the collateral token seized
    /// @param seized the quantity of collateral tokens seized from the position
    /// @param debtType the type identifier string of the debt token being repaid
    /// @param repaid the quantity of debt tokens repaid via the DEX swap
    /// @param slippageBps the slippage tolerance in basis points for the DEX swap
    /// @param newHF the position's health factor after the liquidation
    access(all) event LiquidationExecutedViaDex(
        pid: UInt64,
        poolUUID: UInt64,
        seizeType: String,
        seized: UFix64,
        debtType: String,
        repaid: UFix64,
        slippageBps: UInt16,
        newHF: UFix128
    )

    /// Emitted when the price oracle for a pool is replaced by governance.
    ///
    /// @param poolUUID the UUID of the pool whose oracle was updated
    /// @param newOracleType the Cadence type identifier string of the new oracle implementation
    access(all) event PriceOracleUpdated(
        poolUUID: UInt64,
        newOracleType: String
    )

    /// Emitted when the interest rate curve for a token is changed by governance.
    /// Interest accrued at the old rate is compounded before the switch takes effect.
    ///
    /// @param poolUUID the UUID of the pool containing the token
    /// @param tokenType the type identifier string of the token whose curve changed
    /// @param curveType the Cadence type identifier string of the new interest curve implementation
    access(all) event InterestCurveUpdated(
        poolUUID: UInt64,
        tokenType: String,
        curveType: String
    )

    /// Emitted when the insurance rate for a token is updated by governance.
    /// The insurance rate is an annual fraction of debit interest diverted to the insurance fund.
    ///
    /// @param poolUUID the UUID of the pool containing the token
    /// @param tokenType the type identifier string of the token whose rate changed
    /// @param insuranceRate the new annual insurance rate (e.g. 0.001 for 0.1%)
    access(all) event InsuranceRateUpdated(
        poolUUID: UInt64,
        tokenType: String,
        insuranceRate: UFix64
    )

    /// Emitted when an insurance fee is collected for a token and deposited into the insurance fund.
    /// The collected amount is denominated in MOET after swapping from the source token.
    ///
    /// @param poolUUID the UUID of the pool from which insurance was collected
    /// @param tokenType the type identifier string of the source token
    /// @param insuranceAmount the quantity of MOET collected for the insurance fund
    /// @param collectionTime the timestamp of the collection
    access(all) event InsuranceFeeCollected(
        poolUUID: UInt64,
        tokenType: String,
        insuranceAmount: UFix64,
        collectionTime: UFix64
    )

    /// Emitted when the stability fee rate for a token is updated by governance.
    /// The stability fee rate is an annual fraction of debit interest diverted to the stability fund.
    ///
    /// @param poolUUID the UUID of the pool containing the token
    /// @param tokenType the type identifier string of the token whose rate changed
    /// @param stabilityFeeRate the new annual stability fee rate (e.g. 0.05 for 5%)
    access(all) event StabilityFeeRateUpdated(
        poolUUID: UInt64,
        tokenType: String,
        stabilityFeeRate: UFix64
    )

    /// Emitted when a stability fee is collected for a token and deposited into the stability fund.
    /// The collected amount is denominated in the source token type.
    ///
    /// @param poolUUID the UUID of the pool from which the fee was collected
    /// @param tokenType the type identifier string of the token collected
    /// @param stabilityAmount the quantity of tokens collected for the stability fund
    /// @param collectionTime the timestamp of the collection
    access(all) event StabilityFeeCollected(
        poolUUID: UInt64,
        tokenType: String,
        stabilityAmount: UFix64,
        collectionTime: UFix64
    )

    /// Emitted when governance withdraws funds from the stability fund for a token.
    ///
    /// @param poolUUID the UUID of the pool from which stability funds are withdrawn
    /// @param tokenType the type identifier string of the withdrawn token
    /// @param amount the quantity of tokens withdrawn from the stability fund
    access(all) event StabilityFundWithdrawn(
        poolUUID: UInt64,
        tokenType: String,
        amount: UFix64
    )

    /// Emitted when a token's deposit capacity cap is regenerated based on elapsed time.
    /// Capacity regeneration increases the maximum amount that can be deposited for a token.
    ///
    /// @param tokenType the Cadence type of the token whose capacity was regenerated
    /// @param oldCapacityCap the previous deposit capacity cap
    /// @param newCapacityCap the new deposit capacity cap after regeneration
    access(all) event DepositCapacityRegenerated(
        tokenType: Type,
        oldCapacityCap: UFix64,
        newCapacityCap: UFix64
    )

    /// Emitted when deposit capacity is consumed by a deposit into a position.
    /// Deposit capacity limits the rate at which new deposits can enter the pool.
    ///
    /// @param tokenType the Cadence type of the deposited token
    /// @param pid the position identifier that consumed the capacity
    /// @param amount the quantity of capacity consumed
    /// @param remainingCapacity the remaining deposit capacity after consumption
    access(all) event DepositCapacityConsumed(
        tokenType: Type,
        pid: UInt64,
        amount: UFix64,
        remainingCapacity: UFix64
    )

    //////////////////////////
    /// EMISSION FUNCTIONS ///
    //////////////////////////

    /// Emits Opened event. See Opened event definition above for additional details.
    access(account) fun emitOpened(pid: UInt64, poolUUID: UInt64) {
        emit Opened(pid: pid, poolUUID: poolUUID)
    }

    /// Emits Deposited event. See Deposited event definition above for additional details.
    access(account) fun emitDeposited(pid: UInt64, poolUUID: UInt64, vaultType: Type, amount: UFix64, depositedUUID: UInt64) {
        emit Deposited(pid: pid, poolUUID: poolUUID, vaultType: vaultType, amount: amount, depositedUUID: depositedUUID)
    }

    /// Emits Withdrawn event. See Withdrawn event definition above for additional details.
    access(account) fun emitWithdrawn(pid: UInt64, poolUUID: UInt64, vaultType: Type, amount: UFix64, withdrawnUUID: UInt64) {
        emit Withdrawn(pid: pid, poolUUID: poolUUID, vaultType: vaultType, amount: amount, withdrawnUUID: withdrawnUUID)
    }

    /// Emits Rebalanced event. See Rebalanced event definition above for additional details.
    access(account) fun emitRebalanced(pid: UInt64, poolUUID: UInt64, atHealth: UFix128, amount: UFix64, fromUnder: Bool) {
        emit Rebalanced(pid: pid, poolUUID: poolUUID, atHealth: atHealth, amount: amount, fromUnder: fromUnder)
    }

    /// Emits PoolPaused event. See PoolPaused event definition above for additional details.
    access(account) fun emitPoolPaused(poolUUID: UInt64) {
        emit PoolPaused(poolUUID: poolUUID)
    }

    /// Emits PoolUnpaused event. See PoolUnpaused event definition above for additional details.
    access(account) fun emitPoolUnpaused(poolUUID: UInt64, warmupEndsAt: UInt64) {
        emit PoolUnpaused(poolUUID: poolUUID, warmupEndsAt: warmupEndsAt)
    }

    /// Emits LiquidationExecuted event. See LiquidationExecuted event definition above for additional details.
    access(account) fun emitLiquidationExecuted(pid: UInt64, poolUUID: UInt64, debtType: String, repayAmount: UFix64, seizeType: String, seizeAmount: UFix64, newHF: UFix128) {
        emit LiquidationExecuted(pid: pid, poolUUID: poolUUID, debtType: debtType, repayAmount: repayAmount, seizeType: seizeType, seizeAmount: seizeAmount, newHF: newHF)
    }

    /// Emits LiquidationExecutedViaDex event. See LiquidationExecutedViaDex event definition above for additional details.
    access(account) fun emitLiquidationExecutedViaDex(pid: UInt64, poolUUID: UInt64, seizeType: String, seized: UFix64, debtType: String, repaid: UFix64, slippageBps: UInt16, newHF: UFix128) {
        emit LiquidationExecutedViaDex(pid: pid, poolUUID: poolUUID, seizeType: seizeType, seized: seized, debtType: debtType, repaid: repaid, slippageBps: slippageBps, newHF: newHF)
    }

    /// Emits PriceOracleUpdated event. See PriceOracleUpdated event definition above for additional details.
    access(account) fun emitPriceOracleUpdated(poolUUID: UInt64, newOracleType: String) {
        emit PriceOracleUpdated(poolUUID: poolUUID, newOracleType: newOracleType)
    }

    /// Emits InterestCurveUpdated event. See InterestCurveUpdated event definition above for additional details.
    access(account) fun emitInterestCurveUpdated(poolUUID: UInt64, tokenType: String, curveType: String) {
        emit InterestCurveUpdated(poolUUID: poolUUID, tokenType: tokenType, curveType: curveType)
    }

    /// Emits InsuranceRateUpdated event. See InsuranceRateUpdated event definition above for additional details.
    access(account) fun emitInsuranceRateUpdated(poolUUID: UInt64, tokenType: String, insuranceRate: UFix64) {
        emit InsuranceRateUpdated(poolUUID: poolUUID, tokenType: tokenType, insuranceRate: insuranceRate)
    }

    /// Emits InsuranceFeeCollected event. See InsuranceFeeCollected event definition above for additional details.
    access(account) fun emitInsuranceFeeCollected(poolUUID: UInt64, tokenType: String, insuranceAmount: UFix64, collectionTime: UFix64) {
        emit InsuranceFeeCollected(poolUUID: poolUUID, tokenType: tokenType, insuranceAmount: insuranceAmount, collectionTime: collectionTime)
    }

    /// Emits StabilityFeeRateUpdated event. See StabilityFeeRateUpdated event definition above for additional details.
    access(account) fun emitStabilityFeeRateUpdated(poolUUID: UInt64, tokenType: String, stabilityFeeRate: UFix64) {
        emit StabilityFeeRateUpdated(poolUUID: poolUUID, tokenType: tokenType, stabilityFeeRate: stabilityFeeRate)
    }

    /// Emits StabilityFeeCollected event. See StabilityFeeCollected event definition above for additional details.
    access(account) fun emitStabilityFeeCollected(poolUUID: UInt64, tokenType: String, stabilityAmount: UFix64, collectionTime: UFix64) {
        emit StabilityFeeCollected(poolUUID: poolUUID, tokenType: tokenType, stabilityAmount: stabilityAmount, collectionTime: collectionTime)
    }

    /// Emits StabilityFundWithdrawn event. See StabilityFundWithdrawn event definition above for additional details.
    access(account) fun emitStabilityFundWithdrawn(poolUUID: UInt64, tokenType: String, amount: UFix64) {
        emit StabilityFundWithdrawn(poolUUID: poolUUID, tokenType: tokenType, amount: amount)
    }

    /// Emits DepositCapacityRegenerated event. See DepositCapacityRegenerated event definition above for additional details.
    access(account) fun emitDepositCapacityRegenerated(tokenType: Type, oldCapacityCap: UFix64, newCapacityCap: UFix64) {
        emit DepositCapacityRegenerated(tokenType: tokenType, oldCapacityCap: oldCapacityCap, newCapacityCap: newCapacityCap)
    }

    /// Emits DepositCapacityConsumed event. See DepositCapacityConsumed event definition above for additional details.
    access(account) fun emitDepositCapacityConsumed(tokenType: Type, pid: UInt64, amount: UFix64, remainingCapacity: UFix64) {
        emit DepositCapacityConsumed(tokenType: tokenType, pid: pid, amount: amount, remainingCapacity: remainingCapacity)
    }
}
