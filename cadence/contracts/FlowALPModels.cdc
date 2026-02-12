import "DeFiActions"

access(all) contract FlowALPModels {

    /// PoolConfig defines the interface for pool-level configuration parameters.
    access(all) struct interface PoolConfig {

        // Getters

        access(all) view fun getPriceOracle(): {DeFiActions.PriceOracle}
        access(all) view fun getCollateralFactor(tokenType: Type): UFix64
        access(all) view fun getBorrowFactor(tokenType: Type): UFix64
        access(all) view fun getPositionsProcessedPerCallback(): UInt64
        access(all) view fun getLiquidationTargetHF(): UFix128
        access(all) view fun getWarmupSec(): UInt64
        access(all) view fun getLastUnpausedAt(): UInt64?
        access(all) view fun getDex(): {DeFiActions.SwapperProvider}
        access(all) view fun getDexOracleDeviationBps(): UInt16

        // Setters

        access(all) fun setPriceOracle(_ newOracle: {DeFiActions.PriceOracle}, defaultToken: Type)
        access(all) fun setCollateralFactor(tokenType: Type, factor: UFix64)
        access(all) fun setBorrowFactor(tokenType: Type, factor: UFix64)
        access(all) fun setPositionsProcessedPerCallback(_ count: UInt64)
        access(all) fun setLiquidationTargetHF(_ targetHF: UFix128)
        access(all) fun setWarmupSec(_ warmupSec: UInt64)
        access(all) fun setLastUnpausedAt(_ time: UInt64?)
        access(all) fun setDex(_ dex: {DeFiActions.SwapperProvider})
        access(all) fun setDexOracleDeviationBps(_ bps: UInt16)
    }

    /// PoolConfigImpl is the concrete implementation of PoolConfig.
    access(all) struct PoolConfigImpl: PoolConfig {

        /// A price oracle that will return the price of each token in terms of the default token.
        access(self) var priceOracle: {DeFiActions.PriceOracle}

        /// Together with borrowFactor, collateralFactor determines borrowing limits for each token.
        ///
        /// When determining the withdrawable loan amount, the value of the token (provided by the PriceOracle)
        /// is multiplied by the collateral factor.
        ///
        /// The total "effective collateral" for a position is the value of each token deposited to the position
        /// multiplied by its collateral factor.
        access(self) var collateralFactor: {Type: UFix64}

        /// Together with collateralFactor, borrowFactor determines borrowing limits for each token.
        ///
        /// The borrowFactor determines how much of a position's "effective collateral" can be borrowed against as a
        /// percentage between 0.0 and 1.0
        access(self) var borrowFactor: {Type: UFix64}

        /// The count of positions to update per asynchronous update
        access(self) var positionsProcessedPerCallback: UInt64

        /// The target health factor when liquidating a position, which limits how much collateral can be liquidated.
        /// After a liquidation, the position's health factor must be less than or equal to this target value.
        access(self) var liquidationTargetHF: UFix128

        /// Period (s) following unpause in which liquidations are still not allowed
        access(self) var warmupSec: UInt64
        /// Time this pool most recently was unpaused
        access(self) var lastUnpausedAt: UInt64?

        /// A trusted DEX (or set of DEXes) used by FlowALPv1 as a pricing oracle and trading counterparty for liquidations.
        /// The SwapperProvider implementation MUST return a Swapper for all possible (ordered) pairs of supported tokens.
        /// If [X1, X2, ..., Xn] is the set of supported tokens, then the SwapperProvider must return a Swapper for all pairs:
        ///   (Xi, Xj) where i∈[1,n], j∈[1,n], i≠j
        ///
        /// FlowALPv1 does not attempt to construct multi-part paths (using multiple Swappers) or compare prices across Swappers.
        /// It relies directly on the Swapper's returned by the configured SwapperProvider.
        access(self) var dex: {DeFiActions.SwapperProvider}

        /// Max allowed deviation in basis points between DEX-implied price and oracle price.
        access(self) var dexOracleDeviationBps: UInt16

        init(
            priceOracle: {DeFiActions.PriceOracle},
            collateralFactor: {Type: UFix64},
            borrowFactor: {Type: UFix64},
            positionsProcessedPerCallback: UInt64,
            liquidationTargetHF: UFix128,
            warmupSec: UInt64,
            lastUnpausedAt: UInt64?,
            dex: {DeFiActions.SwapperProvider},
            dexOracleDeviationBps: UInt16,
        ) {
            self.priceOracle = priceOracle
            self.collateralFactor = collateralFactor
            self.borrowFactor = borrowFactor
            self.positionsProcessedPerCallback = positionsProcessedPerCallback
            self.liquidationTargetHF = liquidationTargetHF
            self.warmupSec = warmupSec
            self.lastUnpausedAt = lastUnpausedAt
            self.dex = dex
            self.dexOracleDeviationBps = dexOracleDeviationBps
        }

        // Getters

        access(all) view fun getPriceOracle(): {DeFiActions.PriceOracle} {
            return self.priceOracle
        }

        access(all) view fun getCollateralFactor(tokenType: Type): UFix64 {
            return self.collateralFactor[tokenType]!
        }

        access(all) view fun getBorrowFactor(tokenType: Type): UFix64 {
            return self.borrowFactor[tokenType]!
        }

        access(all) view fun getPositionsProcessedPerCallback(): UInt64 {
            return self.positionsProcessedPerCallback
        }

        access(all) view fun getLiquidationTargetHF(): UFix128 {
            return self.liquidationTargetHF
        }

        access(all) view fun getWarmupSec(): UInt64 {
            return self.warmupSec
        }

        access(all) view fun getLastUnpausedAt(): UInt64? {
            return self.lastUnpausedAt
        }

        access(all) view fun getDex(): {DeFiActions.SwapperProvider} {
            return self.dex
        }

        access(all) view fun getDexOracleDeviationBps(): UInt16 {
            return self.dexOracleDeviationBps
        }

        // Setters

        access(all) fun setPriceOracle(_ newOracle: {DeFiActions.PriceOracle}, defaultToken: Type) {
            pre {
                newOracle.unitOfAccount() == defaultToken:
                    "Price oracle must return prices in terms of the pool's default token"
            }
            self.priceOracle = newOracle
        }

        access(all) fun setCollateralFactor(tokenType: Type, factor: UFix64) {
            pre {
                factor > 0.0 && factor <= 1.0:
                    "Collateral factor must be between 0 and 1"
            }
            self.collateralFactor[tokenType] = factor
        }

        access(all) fun setBorrowFactor(tokenType: Type, factor: UFix64) {
            pre {
                factor > 0.0 && factor <= 1.0:
                    "Borrow factor must be between 0 and 1"
            }
            self.borrowFactor[tokenType] = factor
        }

        access(all) fun setPositionsProcessedPerCallback(_ count: UInt64) {
            self.positionsProcessedPerCallback = count
        }

        access(all) fun setLiquidationTargetHF(_ targetHF: UFix128) {
            pre {
                targetHF > 1.0:
                    "targetHF must be > 1.0"
            }
            self.liquidationTargetHF = targetHF
        }

        access(all) fun setWarmupSec(_ warmupSec: UInt64) {
            self.warmupSec = warmupSec
        }

        access(all) fun setLastUnpausedAt(_ time: UInt64?) {
            self.lastUnpausedAt = time
        }

        access(all) fun setDex(_ dex: {DeFiActions.SwapperProvider}) {
            self.dex = dex
        }

        access(all) fun setDexOracleDeviationBps(_ bps: UInt16) {
            self.dexOracleDeviationBps = bps
        }
    }
}
