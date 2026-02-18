import "FlowToken"
import "DeFiActions"
import "FlowTransactionScheduler"

access(all) contract FlowPriceOracleAggregatorv1 {

    access(all) entitlement Governance

    access(all) event AggregatorCreated(uuid: UInt64)
    access(all) event PriceNotAvailable()
    access(all) event PriceNotWithinSpreadTolerance(spread: UFix64)
    access(all) event PriceNotStable(gradient: UFix64)

    access(self) var oracleAggregators: @{UInt64: PriceOracleAggregatorStorage}

    access(all) resource PriceOracleAggregatorStorage {
        access(all) let priceHistory: [PriceHistoryEntry]

        // constants intentional to avoid stupid bugs
        access(all) let oracles: [{DeFiActions.PriceOracle}]
        access(all) let maxSpread: UFix64
        // % change per minute
        access(all) let maxGradient: UFix64
        access(all) let priceHistorySize: Int
        access(all) let priceHistoryInterval: UFix64
        access(all) let maxPriceHistoryAge: UFix64

        access(all) let unit: Type

        init(
            oracles: [{DeFiActions.PriceOracle}],
            maxSpread: UFix64,
            maxGradient: UFix64,
            priceHistorySize: Int,
            priceHistoryInterval: UFix64,
            maxPriceHistoryAge: UFix64,
            unitOfAccount: Type,
        ) {
            self.oracles = oracles
            self.priceHistory = []
            self.maxSpread = maxSpread
            self.maxGradient = maxGradient
            self.priceHistorySize = priceHistorySize
            self.priceHistoryInterval = priceHistoryInterval
            self.maxPriceHistoryAge = maxPriceHistoryAge
            self.unit = unitOfAccount
        }

        access(all) fun price(ofToken: Type): UFix64? {
            let price = self.getPriceUncheckedGradient(ofToken: ofToken)
            if price == nil {
                return nil
            }
            self.tryAddPriceToHistoryInternal(price: price!)
            if !self.isGradientStable(currentPrice: price!) {
                return nil
            }
            return price
        }

        access(self) fun getPriceUncheckedGradient(ofToken: Type): UFix64? {
            let prices = self.getPrices(ofToken: ofToken)
            if prices == nil || prices!.length == 0 {
                return nil
            }
            let minAndMaxPrices = self.getMinAndMaxPrices(prices: prices!)
            if !self.isWithinSpreadTolerance(minPrice: minAndMaxPrices.min, maxPrice: minAndMaxPrices.max) {
                return nil
            }
            return self.trimmedMeanPrice(
                prices: prices!,
                minPrice: minAndMaxPrices.min,
                maxPrice: minAndMaxPrices.max,
            )
        }

        access(self) fun getPrices(ofToken: Type): [UFix64]? {
            let prices: [UFix64] = []
            for oracle in self.oracles {
                let price = oracle.price(ofToken: ofToken)
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

        access(self) view fun isWithinSpreadTolerance(minPrice: UFix64, maxPrice: UFix64): Bool {
            let spread = (maxPrice - minPrice) / minPrice
            if spread > self.maxSpread {
                emit PriceNotWithinSpreadTolerance(spread: spread)
                return false
            }
            return true
        }

        access(self) view fun trimmedMeanPrice(prices: [UFix64], minPrice: UFix64, maxPrice: UFix64): UFix64? {
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
                    // if price got measured in the same block allow for some price jitter
                    deltaT = 1.0
                }
                if deltaT > self.maxPriceHistoryAge {
                    continue
                }
                var gradient = 0.0
                if currentPrice > entry.price {
                    gradient = (currentPrice - entry.price) / (entry.price * deltaT) * 6000.0
                } else {
                    gradient = (entry.price - currentPrice) / (currentPrice * deltaT) * 6000.0
                }
                if gradient > self.maxGradient {
                    emit PriceNotStable(gradient: gradient)
                    return false
                }
            }
            return true
        }

        // Permissionless can be called by anyone, idempotent
        access(all) fun tryAddPriceToHistory() {
            let price = self.getPriceUncheckedGradient(ofToken: self.unit)
            if price == nil {
                return
            }
            self.tryAddPriceToHistoryInternal(price: price!)
        }

        access(self) fun tryAddPriceToHistoryInternal(price: UFix64) {
            // Check if enough time has passed since the last entry
            if self.priceHistory.length > 0 {
                let lastEntry = self.priceHistory[self.priceHistory.length - 1]
                let timeSinceLastEntry = getCurrentBlock().timestamp - lastEntry.timestamp
                if timeSinceLastEntry < self.priceHistoryInterval {
                    return
                }
            }
            self.priceHistory.append(PriceHistoryEntry(price: price, timestamp: getCurrentBlock().timestamp))
            if self.priceHistory.length > self.priceHistorySize {
                self.priceHistory.removeFirst()
            }
        }
    }

    access(all) struct PriceOracleAggregator: DeFiActions.PriceOracle {
        access(all) let priceOracleID: UInt64
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        init(priceOracleID: UInt64) {
            self.priceOracleID = priceOracleID
            self.uniqueID = DeFiActions.createUniqueIdentifier()
        }

        access(all) fun price(ofToken: Type): UFix64? {
            return self.borrowPriceOracleAggregator().price(ofToken: ofToken)
        }

        access(all) view fun unitOfAccount(): Type {
            return self.borrowPriceOracleAggregator().unit
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
            return (&FlowPriceOracleAggregatorv1.oracleAggregators[self.priceOracleID])!
        }
    }

    access(all) resource PriceOracleCronHandler: FlowTransactionScheduler.TransactionHandler{
        access(all) let priceOracleID: UInt64

        init(priceOracleID: UInt64) {
            self.priceOracleID = priceOracleID
        }

        access(FlowTransactionScheduler.Execute) fun executeTransaction(id: UInt64, data: AnyStruct?) {
            let priceOracleAggregator = self.borrowPriceOracleAggregator()
            priceOracleAggregator.tryAddPriceToHistory()
        }

        access(self) view fun borrowPriceOracleAggregator(): &PriceOracleAggregatorStorage {
            return (&FlowPriceOracleAggregatorv1.oracleAggregators[self.priceOracleID])!
        }
    }

    access(all) fun createPriceOracleAggregatorStorage(
        oracles: [{DeFiActions.PriceOracle}],
        maxSpread: UFix64,
        maxGradient: UFix64,
        priceHistorySize: Int,
        priceHistoryInterval: UFix64,
        maxPriceHistoryAge: UFix64,
        unitOfAccount: Type,
    ): UInt64 {
        let priceOracleAggregator <- create PriceOracleAggregatorStorage(
            oracles: oracles,
            maxSpread: maxSpread,
            maxGradient: maxGradient,
            priceHistorySize: priceHistorySize,
            priceHistoryInterval: priceHistoryInterval,
            maxPriceHistoryAge: maxPriceHistoryAge,
            unitOfAccount: unitOfAccount
        )
        let id = priceOracleAggregator.uuid
        self.oracleAggregators[id] <-! priceOracleAggregator
        emit AggregatorCreated(uuid: id)
        return id
    }

    access(all) fun createPriceOracleAggregator(id: UInt64): PriceOracleAggregator {
        return PriceOracleAggregator(priceOracleID: id)
    }

    access(all) fun createPriceOracleCronHandler(id: UInt64): @PriceOracleCronHandler {
        return <- create PriceOracleCronHandler(priceOracleID: id)
    }

    access(all) struct MinAndMaxPrices {
        access(all) let min: UFix64
        access(all) let max: UFix64

        init(min: UFix64, max: UFix64) {
            self.min = min
            self.max = max
        }
    }

    access(all) struct PriceHistoryEntry {
        access(all) let price: UFix64
        access(all) let timestamp: UFix64

        init(price: UFix64, timestamp: UFix64) {
            self.price = price
            self.timestamp = timestamp
        }
    }

    init() {
        self.oracleAggregators <- {}
    }
}