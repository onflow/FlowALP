import "FlowToken"
import "DeFiActions"
import "FlowTransactionScheduler"

/// FlowPriceOracleAggregatorv1 combines multiple `DeFiActions.PriceOracle`
/// sources into a single trusted oracle. A price is returned only when:
/// - All oracles return a value (no missing data),
/// - The spread between min and max oracle prices is within `maxSpread`,
/// - Short-term price gradient vs. recent history is within `maxGradient`.
///
/// One aggregator instance = one market (one token type). For multiple
/// markets, create one storage per market and use a router to expose them.
/// Config is immutable at creation to avoid accidental changes in production.
access(all) contract FlowPriceOracleAggregatorv1 {

    /// Emitted when a new aggregator storage is created.
    access(all) event StorageCreated(storageID: UInt64)
    /// At least one underlying oracle did not return a price for the requested
    /// token.
    access(all) event PriceNotAvailable()
    /// Spread between min and max oracle prices exceeded the configured
    /// tolerance.
    access(all) event PriceNotWithinSpreadTolerance(spread: UFix64)
    /// Short-term price change (gradient) exceeded the configured tolerance.
    access(all) event PriceNotWithinGradientTolerance(gradient: UFix64)
    /// storageID -> PriceOracleAggregatorStorage
    access(self) var storage: @{UInt64: PriceOracleAggregatorStorage}

    init() {
        self.storage <- {}
    }

    /// Storage resource for one aggregated oracle (single market): a fixed
    /// set of oracles, tolerances, and an array of recent prices for gradient
    /// (stability) checks. Immutable: no post-creation config change to avoid
    /// accidental misconfiguration in production.
    access(all) resource PriceOracleAggregatorStorage {
        /// Token type for this oracle.
        access(all) let ofToken: Type
        /// Recent prices for gradient (stability) checks.
        access(all) let priceHistory: [PriceHistoryEntry]
        /// Fixed set of oracles.
        access(all) let oracles: [{DeFiActions.PriceOracle}]
        /// Max allowed relative spread (max-min)/min between oracle prices.
        access(all) let maxSpread: UFix64
        /// Max allowed short-term gradient (effective % change per minute).
        access(all) let maxGradient: UFix64
        /// Length of the price history array for gradient stability checks.
        access(all) let priceHistorySize: Int
        /// Min time between two consecutive history entries.
        access(all) let priceHistoryInterval: UFix64
        /// Maximum age of a price history entry.
        /// History entries older than this are ignored when computing gradient
        /// stability.
        access(all) let maxPriceHistoryAge: UFix64
        /// Unit of account type for this oracle.
        access(all) let unitOfAccountType: Type

        init(
            ofToken: Type,
            oracles: [{DeFiActions.PriceOracle}],
            maxSpread: UFix64,
            maxGradient: UFix64,
            priceHistorySize: Int,
            priceHistoryInterval: UFix64,
            maxPriceHistoryAge: UFix64,
            unitOfAccount: Type,
        ) {
            self.ofToken = ofToken
            self.oracles = oracles
            self.priceHistory = []
            self.maxSpread = maxSpread
            self.maxGradient = maxGradient
            self.priceHistorySize = priceHistorySize
            self.priceHistoryInterval = priceHistoryInterval
            self.maxPriceHistoryAge = maxPriceHistoryAge
            self.unitOfAccountType = unitOfAccount
        }

        /// Returns aggregated price for `ofToken` or nil if
        /// - no oracle defined for `ofToken`,
        /// - oracle returned nil,
        /// - spread between min and max prices is too high,
        /// - gradient is too high.
        access(all) fun price(ofToken: Type): UFix64? {
            pre {
                self.ofToken == ofToken: "ofToken type mismatch"
            }
            let price = self.getPriceUncheckedGradient()
            if price == nil {
                return nil
            }
            self.tryAddPriceToHistoryInternal(price: price!)
            if !self.isGradientStable(currentPrice: price!) {
                return nil
            }
            return price
        }

        /// Permissionless: anyone may call. Appends current aggregated price
        /// to history if available and interval has elapsed.
        /// Idempotent; safe to call from a cron/scheduler.
        access(all) fun tryAddPriceToHistory() {
            let price = self.getPriceUncheckedGradient()
            if price == nil {
                return
            }
            self.tryAddPriceToHistoryInternal(price: price!)
        }

        access(self) fun getPriceUncheckedGradient(): UFix64? {
            let prices = self.getPrices()
            if prices == nil || prices!.length == 0 {
                return nil
            }
            let minAndMaxPrices = self.getMinAndMaxPrices(prices: prices!)
            if !self.isWithinSpreadTolerance(
                minPrice: minAndMaxPrices.min,
                maxPrice: minAndMaxPrices.max,
            ) {
                return nil
            }
            return self.trimmedMeanPrice(
                prices: prices!,
                minPrice: minAndMaxPrices.min,
                maxPrice: minAndMaxPrices.max,
            )
        }

        access(self) fun getPrices(): [UFix64]? {
            let prices: [UFix64] = []
            for oracle in self.oracles {
                let price = oracle.price(ofToken: self.ofToken)
                if price == nil {
                    emit PriceNotAvailable()
                    return nil
                }
                prices.append(price!)
            }
            return prices
        }

        access(self) fun getMinAndMaxPrices(prices: [UFix64]): MinAndMaxPrices {
            var minPrice = UFix64.max
            var maxPrice = UFix64.min
            for price in prices {
                if price < minPrice {
                    minPrice = price
                }
                if price > maxPrice {
                    maxPrice = price
                }
            }
            return MinAndMaxPrices(min: minPrice, max: maxPrice)
        }

        access(self) view fun isWithinSpreadTolerance(
            minPrice: UFix64,
            maxPrice: UFix64,
        ): Bool {
            let spread = (maxPrice - minPrice) / minPrice
            if spread > self.maxSpread {
                emit PriceNotWithinSpreadTolerance(spread: spread)
                return false
            }
            return true
        }

        access(self) view fun trimmedMeanPrice(
            prices: [UFix64],
            minPrice: UFix64,
            maxPrice: UFix64,
        ): UFix64? {
            let count = prices.length

            // Handle edge cases where trimming isn't possible
            if count == 0 { return nil }
            if count == 1 { return prices[0] }
            if count == 2 { return (prices[0] + prices[1]) / 2.0 }

            var totalSum = 0.0
            for price in prices {
                totalSum = totalSum + price
            }
            let trimmedSum = totalSum - minPrice - maxPrice
            return trimmedSum / UFix64(count - 2)
        }

        access(self) fun isGradientStable(currentPrice: UFix64): Bool {
            let now = getCurrentBlock().timestamp
            for entry in self.priceHistory {
                var deltaT = now - UFix64(entry.timestamp)
                if deltaT == 0.0 {
                    // Same block: allow some jitter (avoid div by zero).
                    deltaT = 1.0
                }
                if deltaT > self.maxPriceHistoryAge {
                    continue
                }
                var gradient = 0.0
                if currentPrice > entry.price {
                    gradient = ((currentPrice - entry.price) * 6000.0)
                            / (entry.price * deltaT)
                } else {
                    gradient = ((entry.price - currentPrice) * 6000.0)
                            / (currentPrice * deltaT)
                }
                if gradient > self.maxGradient {
                    emit PriceNotWithinGradientTolerance(gradient: gradient)
                    return false
                }
            }
            return true
        }

        access(self) fun tryAddPriceToHistoryInternal(price: UFix64) {
            let now = getCurrentBlock().timestamp
            // Only append if enough time has passed since the last entry.
            if self.priceHistory.length > 0 {
                let lastEntry = self.priceHistory[self.priceHistory.length - 1]
                let timeSinceLastEntry = now - lastEntry.timestamp
                if timeSinceLastEntry < self.priceHistoryInterval {
                    return
                }
            }
            let newEntry = PriceHistoryEntry(price: price, timestamp: now)
            self.priceHistory.append(newEntry)
            if self.priceHistory.length > self.priceHistorySize {
                self.priceHistory.removeFirst()
            }
        }
    }

    /// Struct over a `PriceOracleAggregatorStorage`
    /// See `DeFiActions.PriceOracle` for interface documentation.
    ///
    /// Additionaly implements `priceHistory()` to return the price history
    /// array.
    access(all) struct PriceOracleAggregator: DeFiActions.PriceOracle {
        access(all) let storageID: UInt64
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        init(storageID: UInt64) {
            self.storageID = storageID
            self.uniqueID = DeFiActions.createUniqueIdentifier()
        }

        access(all) fun price(ofToken: Type): UFix64? {
            return self.borrowPriceOracleAggregator().price(ofToken: ofToken)
        }

        access(all) view fun unitOfAccount(): Type {
            return self.borrowPriceOracleAggregator().unitOfAccountType
        }

        access(all) fun priceHistory(): &[PriceHistoryEntry] {
            return self.borrowPriceOracleAggregator().priceHistory
        }

        access(all) view fun id(): UInt64 {
            return self.uniqueID!.id
        }

        access(all) fun getID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }

        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
                innerComponents: []
            )
        }

        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) {
            self.uniqueID = id
        }

        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }

        access(self) view fun borrowPriceOracleAggregator(): &PriceOracleAggregatorStorage {
            return (&FlowPriceOracleAggregatorv1.storage[self.storageID])!
        }
    }

    /// Scheduler handler that calls `tryAddPriceToHistory()` on the given
    /// aggregator storage each tick. Use FlowCron for scheduling of this
    /// handler.
    access(all) resource PriceOracleCronHandler: FlowTransactionScheduler.TransactionHandler {
        /// Storage ID of the aggregator to update.
        access(all) let storageID: UInt64

        init(storageID: UInt64) {
            self.storageID = storageID
        }

        /// Function called by the scheduler to update the price history.
        access(FlowTransactionScheduler.Execute) fun executeTransaction(id: UInt64, data: AnyStruct?) {
            let priceOracleAggregator = self.borrowPriceOracleAggregator()
            priceOracleAggregator.tryAddPriceToHistory()
        }

        access(self) view fun borrowPriceOracleAggregator(): &PriceOracleAggregatorStorage {
            return (&FlowPriceOracleAggregatorv1.storage[self.storageID])!
        }
    }

    /// Creates a new aggregator storage with the given oracles and tolerances.
    /// Returns the storage ID (resource UUID) for `createPriceOracleAggregator`
    /// and `createPriceOracleCronHandler`. Config is immutable after creation.
    access(all) fun createPriceOracleAggregatorStorage(
        ofToken: Type,
        oracles: [{DeFiActions.PriceOracle}],
        maxSpread: UFix64,
        maxGradient: UFix64,
        priceHistorySize: Int,
        priceHistoryInterval: UFix64,
        maxPriceHistoryAge: UFix64,
        unitOfAccount: Type,
    ): UInt64 {
        let priceOracleAggregator <- create PriceOracleAggregatorStorage(
            ofToken: ofToken,
            oracles: oracles,
            maxSpread: maxSpread,
            maxGradient: maxGradient,
            priceHistorySize: priceHistorySize,
            priceHistoryInterval: priceHistoryInterval,
            maxPriceHistoryAge: maxPriceHistoryAge,
            unitOfAccount: unitOfAccount
        )
        let id = priceOracleAggregator.uuid
        self.storage[id] <-! priceOracleAggregator
        emit StorageCreated(storageID: id)
        return id
    }

    /// Returns a `PriceOracleAggregator` which implements
    /// `DeFiActions.PriceOracle` for the given storage.
    access(all) fun createPriceOracleAggregator(storageID: UInt64): PriceOracleAggregator {
        return PriceOracleAggregator(storageID: storageID)
    }

    /// Creates a cron handler that can be used to update the price history
    /// for the given storage. Must be stored and registered with FlowCron.
    access(all) fun createPriceOracleCronHandler(storageID: UInt64): @PriceOracleCronHandler {
        return <- create PriceOracleCronHandler(storageID: storageID)
    }

    /// Helper struct to store the min and max of a set of prices.
    access(all) struct MinAndMaxPrices {
        access(all) let min: UFix64
        access(all) let max: UFix64

        init(min: UFix64, max: UFix64) {
            self.min = min
            self.max = max
        }
    }

    /// Struct to store one entry in the aggregator's price history array for
    /// gradient stability checks.
    access(all) struct PriceHistoryEntry {
        access(all) let price: UFix64
        access(all) let timestamp: UFix64

        init(price: UFix64, timestamp: UFix64) {
            self.price = price
            self.timestamp = timestamp
        }
    }


}