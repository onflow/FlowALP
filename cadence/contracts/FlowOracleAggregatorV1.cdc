import "FlowToken"
import "DeFiActions"

access(all) contract FlowOracleAggregatorV1 {

    access(all) entitlement Governance

    access(all) struct PriceOracleAggregator: DeFiActions.PriceOracle {
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?
        access(self) let unit: Type
        access(all) let oracles: [{DeFiActions.PriceOracle}]

        access(all) var maxSpread: UFix64

        init(uniqueID: DeFiActions.UniqueIdentifier?, unitOfAccount: Type, maxSpread: UFix64) {
            self.uniqueID = uniqueID
            self.unit = unitOfAccount
            self.oracles = []
            self.maxSpread = maxSpread
        }

        access(all) view fun unitOfAccount(): Type {
            return self.unit
        }

        access(all) view fun id(): UInt64? {
            return self.uniqueID?.id
        }

        access(all) fun price(ofToken: Type): UFix64? {
            let prices = self.getPrices()
            if prices.length == 0 {
                return nil
            }
            let minAndMaxPrices = self.getMinAndMaxPrices(prices: prices)
            if !self.isWithinSpreadTolerance(minPrice: minAndMaxPrices.minPrice, maxPrice: minAndMaxPrices.maxPrice) {
                return nil
            }
            return self.trimmedMeanPrice(prices: prices, minPrice: minAndMaxPrices.minPrice, maxPrice: minAndMaxPrices.maxPrice)
        }

        access(all) fun getID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }

        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) {
            self.uniqueID = id
        }

        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
                innerComponents: []
            )
        }

        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }

        access(Governance) fun setMaxSpread(_ maxSpread: UFix64) {
            self.maxSpread = maxSpread
        }

        access(self) fun getMaxSpread(): UFix64 {
            return self.maxSpread
        }

        access(self) fun getPrices(): [UFix64] {
            let prices: [UFix64] = []
            for oracle in self.oracles {
                let price = oracle.price(ofToken: self.unit)
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
            return MinAndMaxPrices(minPrice: minPrice, maxPrice: maxPrice)
        }

        access(self) view fun trimmedMeanPrice(prices: [UFix64], minPrice: UFix64, maxPrice: UFix64): UFix64? {
            switch prices.length {
            case 0:
                return nil
            case 1:
                return prices[0]
            case 2:
                return (prices[0] + prices[1]) / 2.0
            }
            var sum = 0.0
            for price in prices {
                if price != minPrice && price != maxPrice {
                    sum = sum + price
                }
            }
            sum = sum - (minPrice + maxPrice)
            return sum / UFix64(prices.length - 2)
        }

        access(self) view fun isWithinSpreadTolerance(minPrice: UFix64, maxPrice: UFix64): Bool {
            let spread = (maxPrice - minPrice) / minPrice
            return spread <= self.maxSpread
        }
    }

    access(all) fun createPriceOracleAggregator(uniqueID: DeFiActions.UniqueIdentifier?, unitOfAccount: Type, maxSpread: UFix64): PriceOracleAggregator {
        return PriceOracleAggregator(uniqueID: uniqueID, unitOfAccount: unitOfAccount, maxSpread: maxSpread)
    }

    access(all) struct MinAndMaxPrices {
        access(all) let minPrice: UFix64
        access(all) let maxPrice: UFix64

        init(minPrice: UFix64, maxPrice: UFix64) {
            self.minPrice = minPrice
            self.maxPrice = maxPrice
        }
    }
}