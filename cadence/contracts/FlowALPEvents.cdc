access(all) contract FlowALPEvents {

    access(all) event Opened(
        pid: UInt64,
        poolUUID: UInt64
    )

    access(all) event Deposited(
        pid: UInt64,
        poolUUID: UInt64,
        vaultType: Type,
        amount: UFix64,
        depositedUUID: UInt64
    )

    access(all) event Withdrawn(
        pid: UInt64,
        poolUUID: UInt64,
        vaultType: Type,
        amount: UFix64,
        withdrawnUUID: UInt64
    )

    access(all) event Rebalanced(
        pid: UInt64,
        poolUUID: UInt64,
        atHealth: UFix128,
        amount: UFix64,
        fromUnder: Bool
    )

    access(all) event PoolPaused(
        poolUUID: UInt64
    )

    access(all) event PoolUnpaused(
        poolUUID: UInt64,
        warmupEndsAt: UInt64
    )

    access(all) event LiquidationExecuted(
        pid: UInt64,
        poolUUID: UInt64,
        debtType: String,
        repayAmount: UFix64,
        seizeType: String,
        seizeAmount: UFix64,
        newHF: UFix128
    )

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

    access(all) event PriceOracleUpdated(
        poolUUID: UInt64,
        newOracleType: String
    )

    access(all) event InterestCurveUpdated(
        poolUUID: UInt64,
        tokenType: String,
        curveType: String
    )

    access(all) event InsuranceRateUpdated(
        poolUUID: UInt64,
        tokenType: String,
        insuranceRate: UFix64
    )

    access(all) event InsuranceFeeCollected(
        poolUUID: UInt64,
        tokenType: String,
        insuranceAmount: UFix64,
        collectionTime: UFix64
    )

    access(all) event StabilityFeeRateUpdated(
        poolUUID: UInt64,
        tokenType: String,
        stabilityFeeRate: UFix64
    )

    access(all) event StabilityFeeCollected(
        poolUUID: UInt64,
        tokenType: String,
        stabilityAmount: UFix64,
        collectionTime: UFix64
    )

    access(all) event StabilityFundWithdrawn(
        poolUUID: UInt64,
        tokenType: String,
        amount: UFix64
    )

    access(all) event DepositCapacityRegenerated(
        tokenType: Type,
        oldCapacityCap: UFix64,
        newCapacityCap: UFix64
    )

    access(all) event DepositCapacityConsumed(
        tokenType: Type,
        pid: UInt64,
        amount: UFix64,
        remainingCapacity: UFix64
    )

    /* --- EMISSION FUNCTIONS --- */

    access(account) fun emitOpened(pid: UInt64, poolUUID: UInt64) {
        emit Opened(pid: pid, poolUUID: poolUUID)
    }

    access(account) fun emitDeposited(pid: UInt64, poolUUID: UInt64, vaultType: Type, amount: UFix64, depositedUUID: UInt64) {
        emit Deposited(pid: pid, poolUUID: poolUUID, vaultType: vaultType, amount: amount, depositedUUID: depositedUUID)
    }

    access(account) fun emitWithdrawn(pid: UInt64, poolUUID: UInt64, vaultType: Type, amount: UFix64, withdrawnUUID: UInt64) {
        emit Withdrawn(pid: pid, poolUUID: poolUUID, vaultType: vaultType, amount: amount, withdrawnUUID: withdrawnUUID)
    }

    access(account) fun emitRebalanced(pid: UInt64, poolUUID: UInt64, atHealth: UFix128, amount: UFix64, fromUnder: Bool) {
        emit Rebalanced(pid: pid, poolUUID: poolUUID, atHealth: atHealth, amount: amount, fromUnder: fromUnder)
    }

    access(account) fun emitPoolPaused(poolUUID: UInt64) {
        emit PoolPaused(poolUUID: poolUUID)
    }

    access(account) fun emitPoolUnpaused(poolUUID: UInt64, warmupEndsAt: UInt64) {
        emit PoolUnpaused(poolUUID: poolUUID, warmupEndsAt: warmupEndsAt)
    }

    access(account) fun emitLiquidationExecuted(pid: UInt64, poolUUID: UInt64, debtType: String, repayAmount: UFix64, seizeType: String, seizeAmount: UFix64, newHF: UFix128) {
        emit LiquidationExecuted(pid: pid, poolUUID: poolUUID, debtType: debtType, repayAmount: repayAmount, seizeType: seizeType, seizeAmount: seizeAmount, newHF: newHF)
    }

    access(account) fun emitLiquidationExecutedViaDex(pid: UInt64, poolUUID: UInt64, seizeType: String, seized: UFix64, debtType: String, repaid: UFix64, slippageBps: UInt16, newHF: UFix128) {
        emit LiquidationExecutedViaDex(pid: pid, poolUUID: poolUUID, seizeType: seizeType, seized: seized, debtType: debtType, repaid: repaid, slippageBps: slippageBps, newHF: newHF)
    }

    access(account) fun emitPriceOracleUpdated(poolUUID: UInt64, newOracleType: String) {
        emit PriceOracleUpdated(poolUUID: poolUUID, newOracleType: newOracleType)
    }

    access(account) fun emitInterestCurveUpdated(poolUUID: UInt64, tokenType: String, curveType: String) {
        emit InterestCurveUpdated(poolUUID: poolUUID, tokenType: tokenType, curveType: curveType)
    }

    access(account) fun emitInsuranceRateUpdated(poolUUID: UInt64, tokenType: String, insuranceRate: UFix64) {
        emit InsuranceRateUpdated(poolUUID: poolUUID, tokenType: tokenType, insuranceRate: insuranceRate)
    }

    access(account) fun emitInsuranceFeeCollected(poolUUID: UInt64, tokenType: String, insuranceAmount: UFix64, collectionTime: UFix64) {
        emit InsuranceFeeCollected(poolUUID: poolUUID, tokenType: tokenType, insuranceAmount: insuranceAmount, collectionTime: collectionTime)
    }

    access(account) fun emitStabilityFeeRateUpdated(poolUUID: UInt64, tokenType: String, stabilityFeeRate: UFix64) {
        emit StabilityFeeRateUpdated(poolUUID: poolUUID, tokenType: tokenType, stabilityFeeRate: stabilityFeeRate)
    }

    access(account) fun emitStabilityFeeCollected(poolUUID: UInt64, tokenType: String, stabilityAmount: UFix64, collectionTime: UFix64) {
        emit StabilityFeeCollected(poolUUID: poolUUID, tokenType: tokenType, stabilityAmount: stabilityAmount, collectionTime: collectionTime)
    }

    access(account) fun emitStabilityFundWithdrawn(poolUUID: UInt64, tokenType: String, amount: UFix64) {
        emit StabilityFundWithdrawn(poolUUID: poolUUID, tokenType: tokenType, amount: amount)
    }

    access(account) fun emitDepositCapacityRegenerated(tokenType: Type, oldCapacityCap: UFix64, newCapacityCap: UFix64) {
        emit DepositCapacityRegenerated(tokenType: tokenType, oldCapacityCap: oldCapacityCap, newCapacityCap: newCapacityCap)
    }

    access(account) fun emitDepositCapacityConsumed(tokenType: Type, pid: UInt64, amount: UFix64, remainingCapacity: UFix64) {
        emit DepositCapacityConsumed(tokenType: tokenType, pid: pid, amount: amount, remainingCapacity: remainingCapacity)
    }
}
