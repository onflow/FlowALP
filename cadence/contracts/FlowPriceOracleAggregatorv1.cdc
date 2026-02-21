import "FlowToken"
import "DeFiActions"
import "FlowTransactionScheduler"

/// FlowPriceOracleAggregatorv1 combines multiple `DeFiActions.PriceOracle`
/// sources into a single trusted oracle. A price is returned only when:
/// - All oracles return a value (no missing data),
/// - The spread between min and max oracle prices is within `maxSpread`,
/// - Short-term price history is stable.
///
/// One aggregator instance = one market (one token type). For multiple
/// markets, create one storage per market and use a router to expose them.
/// Config is immutable at creation to avoid accidental changes in production.
access(all) contract FlowPriceOracleAggregatorv1 {

    /// Emitted when a new aggregator storage is created.
    access(all) event StorageCreated(storageID: UInt64)
    /// At least one underlying oracle did not return a price for the requested
    /// token.
    access(all) event PriceNotAvailable(oracleType: Type)
    /// Spread between min and max oracle prices exceeded the configured
    /// tolerance.
    access(all) event PriceNotWithinSpreadTolerance(
        spread: UFix64,
        maxAllowedSpread: UFix64
    )
    /// Short-term price change exceeded the configured tolerance.
    access(all) event PriceNotWithinHistoryTolerance(
        relativeDiff: UFix64,
        deltaTMinutes: UFix64,
        maxAllowedRelativeDiff: UFix64
    )
    /// storageID -> PriceOracleAggregatorStorage
    access(self) var storage: @{UInt64: PriceOracleAggregatorStorage}

    init() {
        self.storage <- {}
    }

    /// Storage resource for one aggregated oracle (single market): a fixed
    /// set of oracles, tolerances, and an array of recent prices for history
    /// (stability) checks. Immutable: no post-creation config change to avoid
    /// accidental misconfiguration in production.
    access(all) resource PriceOracleAggregatorStorage {
        /// Token type for this oracle.
        access(all) let ofToken: Type
        /// Recent prices for history stability checks.
        access(all) let priceHistory: [PriceHistoryEntry]
        /// Fixed set of oracles.
        access(all) let oracles: [{DeFiActions.PriceOracle}]
        /// Max allowed relative spread (max-min)/min between oracle prices.
        access(all) let maxSpread: UFix64
        /// Fixed relative buffer to account for immediate market noise.
        access(all) let baseTolerance: UFix64
        /// Additional allowance per minute to account for natural price drift.
        access(all) let driftExpansionRate: UFix64
        /// Size of the price history array.
        access(all) let priceHistorySize: UInt8
        /// Min time between two consecutive history entries.
        access(all) let priceHistoryInterval: UFix64
        /// Maximum age of a price history entry. History entries older than
        /// this are ignored when computing history stability.
        access(all) let maxPriceHistoryAge: UFix64
        /// Minimum number of (non-expired) history entries required for the
        /// history to be considered stable. If fewer entries exist, price()
        /// returns nil.
        access(all) let minimumPriceHistory: UInt8
        /// Unit of account type for this oracle.
        access(all) let unitOfAccountType: Type

        init(
            ofToken: Type,
            oracles: [{DeFiActions.PriceOracle}],
            maxSpread: UFix64,
            baseTolerance: UFix64,
            driftExpansionRate: UFix64,
            priceHistorySize: UInt8,
            priceHistoryInterval: UFix64,
            maxPriceHistoryAge: UFix64,
            minimumPriceHistory: UInt8,
            unitOfAccount: Type,
        ) {
            pre {
                oracles.length > 0:
                    "at least one oracle must be provided"
                maxSpread <= 10000.0:
                    "maxSpread must be <= 10000.0"
                baseTolerance <= 10000.0:
                    "baseTolerance must be <= 10000.0"
                driftExpansionRate <= 10000.0:
                    "driftExpansionRate must be <= 10000.0"
                minimumPriceHistory <= priceHistorySize:
                    "minimumPriceHistory must be <= priceHistorySize"
            }
            self.ofToken = ofToken
            self.oracles = oracles
            self.priceHistory = []
            self.maxSpread = maxSpread
            self.baseTolerance = baseTolerance
            self.driftExpansionRate = driftExpansionRate
            self.priceHistorySize = priceHistorySize
            self.priceHistoryInterval = priceHistoryInterval
            self.maxPriceHistoryAge = maxPriceHistoryAge
            self.minimumPriceHistory = minimumPriceHistory
            self.unitOfAccountType = unitOfAccount
        }

        /// Returns aggregated price for `ofToken` or nil if
        /// - no oracle defined for `ofToken`,
        /// - oracle returned nil,
        /// - spread between min and max prices is too high,
        /// - history is not stable.
        access(all) fun price(ofToken: Type): UFix64? {
            pre {
                self.ofToken == ofToken: "ofToken type mismatch"
            }
            let now = getCurrentBlock().timestamp
            let price = self.getPriceUncheckedHistory(now: now)
            if price == nil {
                return nil
            }
            let validPrice = price!
            if !self.isHistoryStable(currentPrice: validPrice, now: now) {
                return nil
            }
            return validPrice
        }

        /// Permissionless: anyone may call. Appends current aggregated price
        /// to history if available and interval has elapsed.
        /// Idempotent; safe to call from a cron/scheduler.
        access(all) fun tryAddPriceToHistory() {
            let _ = self.getPriceUncheckedHistory(
                now: getCurrentBlock().timestamp
            )
        }

        /// Returns the current aggregated price, checks if it is within spread
        /// tolerance and adds it to the history.
        /// **Does not validate that the history is stable.**
        access(self) fun getPriceUncheckedHistory(now: UFix64): UFix64? {
            let prices = self.getPrices()
            if prices == nil || prices!.length == 0 {
                return nil
            }
            if !self.isWithinSpreadTolerance(prices: prices!) {
                return nil
            }
            let price = self.trimmedMeanPrice(prices: prices!)
            self.tryAddPriceToHistoryInternal(price: price!, now: now)
            return price
        }

        access(self) fun getPrices(): [UFix64]? {
            let prices: [UFix64] = []
            for oracle in self.oracles {
                let price = oracle.price(ofToken: self.ofToken)
                if price == nil {
                    emit PriceNotAvailable(oracleType: oracle.getType())
                    return nil
                }
                prices.append(price!)
            }
            return prices
        }

        access(self) view fun isWithinSpreadTolerance(prices: [UFix64]): Bool {
            if prices.length == 0 {
                return false
            }
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
            if minPrice == 0.0 {
                return false
            }
            let spread = (maxPrice - minPrice) / minPrice
            if spread > self.maxSpread {
                emit PriceNotWithinSpreadTolerance(
                    spread: spread,
                    maxAllowedSpread: self.maxSpread
                )
                return false
            }
            return true
        }

        access(self) view fun trimmedMeanPrice(prices: [UFix64]): UFix64? {
            let count = prices.length

            // Handle edge cases where trimming isn't possible
            if count == 0 { return nil }
            if count == 1 { return prices[0] }
            if count == 2 { return (prices[0] + prices[1]) / 2.0 }

            var totalSum = 0.0
            var minPrice = UFix64.max
            var maxPrice = UFix64.min
            for price in prices {
                if price < minPrice {
                    minPrice = price
                }
                if price > maxPrice {
                    maxPrice = price
                }
                totalSum = totalSum + price
            }
            let trimmedSum = totalSum - minPrice - maxPrice
            return trimmedSum / UFix64(count - 2)
        }

        access(self) fun isHistoryStable(currentPrice: UFix64, now: UFix64): Bool {
            var validEntryCount = 0 as UInt8
            for entry in self.priceHistory {
                let deltaT = now - UFix64(entry.timestamp)

                // Skip entries that are too old to be relevant for the
                // stability check
                if deltaT > self.maxPriceHistoryAge {
                    continue
                }
                validEntryCount = validEntryCount + 1

                // Calculate the absolute relative difference (delta P / P)
                var relativeDiff = 0.0
                if currentPrice > entry.price {
                    let priceDiff = currentPrice - entry.price
                    relativeDiff = priceDiff / entry.price
                } else {
                    let priceDiff = entry.price - currentPrice
                    relativeDiff = priceDiff / currentPrice
                }

                // The "n" component: baseTolerance
                // The "mx" component: driftExpansionRate * deltaT
                let deltaTMinutes = deltaT / 60.0
                let totalAllowedTolerance = self.baseTolerance + (self.driftExpansionRate * deltaTMinutes)

                if relativeDiff > totalAllowedTolerance {
                    emit PriceNotWithinHistoryTolerance(
                        relativeDiff: relativeDiff,
                        deltaTMinutes: deltaTMinutes,
                        maxAllowedRelativeDiff: totalAllowedTolerance
                    )
                    return false
                }
            }
            return validEntryCount >= self.minimumPriceHistory
        }

        access(self) fun tryAddPriceToHistoryInternal(price: UFix64, now: UFix64) {
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
            if self.priceHistory.length > Int(self.priceHistorySize) {
                let _ = self.priceHistory.removeFirst()
            }
        }
    }

    /// Struct over a `PriceOracleAggregatorStorage`
    /// See `DeFiActions.PriceOracle` for interface documentation.
    ///
    /// Additionally implements `priceHistory()` to return the price history
    /// array.
    access(all) struct PriceOracleAggregator: DeFiActions.PriceOracle {
        access(all) let storageID: UInt64
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        init(storageID: UInt64) {
            self.storageID = storageID
            self.uniqueID = DeFiActions.createUniqueIdentifier()
            if FlowPriceOracleAggregatorv1.storage.containsKey(self.storageID) == false {
                panic("Storage not found for storageID: \(self.storageID)")
            }
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
        baseTolerance: UFix64,
        driftExpansionRate: UFix64,
        priceHistorySize: UInt8,
        priceHistoryInterval: UFix64,
        maxPriceHistoryAge: UFix64,
        minimumPriceHistory: UInt8,
        unitOfAccount: Type,
    ): UInt64 {
        let priceOracleAggregator <- create PriceOracleAggregatorStorage(
            ofToken: ofToken,
            oracles: oracles,
            maxSpread: maxSpread,
            baseTolerance: baseTolerance,
            driftExpansionRate: driftExpansionRate,
            priceHistorySize: priceHistorySize,
            priceHistoryInterval: priceHistoryInterval,
            maxPriceHistoryAge: maxPriceHistoryAge,
            minimumPriceHistory: minimumPriceHistory,
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

    /// Struct to store one entry in the aggregator's price history array for
    /// history stability checks.
    access(all) struct PriceHistoryEntry {
        access(all) let price: UFix64
        access(all) let timestamp: UFix64

        init(price: UFix64, timestamp: UFix64) {
            self.price = price
            self.timestamp = timestamp
        }
    }


}