import Test
import BlockchainHelpers

import "FlowPriceOracleAggregatorv1"
import "FlowToken"
import "MOET"
import "MultiMockOracle"
import "test_helpers_price_oracle_aggregator.cdc"
import "test_helpers.cdc"

access(all) var snapshot: UInt64 = 0
access(all) var signer = Test.getAccount(0x0000000000000001)

access(all) fun setup() {
    deployContracts()

    let _ = mintFlow(to: signer, amount: 100.0)
    snapshot = getCurrentBlockHeight()
}

access(all) fun beforeEach() {
    Test.commitBlock()
    Test.reset(to: snapshot)
}

access(all) fun test_single_oracle() {
    let info = createAggregator(
        ofToken: Type<@FlowToken.Vault>(),
        oracleCount: 1,
        maxSpread: 10000.0,
        baseTolerance: 10000.0,
        driftExpansionRate: 10000.0,
        priceHistorySize: 0,
        priceHistoryInterval: 0.0,
        maxPriceHistoryAge: 0.0,
        minimumPriceHistory: 0,
        unitOfAccount: Type<@MOET.Vault>(),
    )
    let prices: [UFix64?] = [1.0, 0.0001, 1337.0]
    for p in prices {
        setMultiMockOraclePrice(
            storageID: info.mockOracleStorageIDs[0],
            forToken: Type<@FlowToken.Vault>(),
            price: p,
        )
        var price = oracleAggregatorPrice(
            storageID: info.aggregatorStorageID,
            ofToken: Type<@FlowToken.Vault>()
        )
        Test.assertEqual(p, price)
    }
}

access(all) fun test_multiple_oracles() {
    let oracleCounts = [1, 2, 3, 4, 5, 6]
    for oracleCount in oracleCounts {
        if snapshot != getCurrentBlockHeight() {
            Test.reset(to: snapshot)
        }
        let info = createAggregator(
            ofToken: Type<@MOET.Vault>(),
            oracleCount: oracleCount,
            maxSpread: 10000.0,
            baseTolerance: 10000.0,
            driftExpansionRate: 10000.0,
            priceHistorySize: 0,
            priceHistoryInterval: 0.0,
            maxPriceHistoryAge: 0.0,
            minimumPriceHistory: 0,
            unitOfAccount: Type<@FlowToken.Vault>(),
        )
        let prices: [UFix64?] = [1.0, 0.0001, 1337.0]
        for p in prices {
            let samePrices: [UFix64?] = []
            var i = 0
            while i < oracleCount {
                samePrices.append(p)
                i = i + 1
            }
            set_prices(info: info, prices: samePrices, forToken: Type<@MOET.Vault>())
            var price = oracleAggregatorPrice(
                storageID: info.aggregatorStorageID,
                ofToken: Type<@MOET.Vault>()
            )
            Test.assertEqual(p, price)
        }
    }
}

access(all) struct TestRunAveragePrice {
    access(all) let prices: [UFix64?]
    access(all) let expectedPrice: UFix64?

    init(prices: [UFix64?], expectedPrice: UFix64?) {
        self.prices = prices
        self.expectedPrice = expectedPrice
    }
}

access(all) fun test_average_price() {
    let testRuns = [TestRunAveragePrice(
        prices: [1.0, 2.0],
        expectedPrice: 1.5,
    ), TestRunAveragePrice(
        prices: [1.0, 2.0, 3.0],
        expectedPrice: 2.0,
    ), TestRunAveragePrice(
        prices: [1.0, 2.0, 10.0],
        expectedPrice: 2.0,
    ), TestRunAveragePrice(
        prices: [1.0, 9.0, 10.0],
        expectedPrice: 9.0,
    ), TestRunAveragePrice(
        prices: [1.0, 1.0, 2.0],
        expectedPrice: 1.0,
    ), TestRunAveragePrice(
        prices: [1.0, 1.0, 1.0],
        expectedPrice: 1.0,
    ), TestRunAveragePrice(
        prices: [1.0, 1.0, 2.0, 3.0],
        expectedPrice: 1.5,
    ), TestRunAveragePrice(
        prices: [1.0, 2.0, 3.0, 4.0, 5.0],
        expectedPrice: 3.0,
    ), TestRunAveragePrice(
        prices: [1.0, 2.0, 3.0, 4.0, 5.0, 6.0],
        expectedPrice: 3.5,
    ), TestRunAveragePrice(
        prices: [1.0, nil, 3.0, 4.0, 5.0, 6.0],
        expectedPrice: nil,
    ), TestRunAveragePrice(
        prices: [1.0, 2.0, 3.0, 4.0, 5.0, nil],
        expectedPrice: nil,
    )]
    let reversedRuns: [TestRunAveragePrice] = []
    for testRun in testRuns {
        reversedRuns.append(TestRunAveragePrice(
            prices: testRun.prices.reverse(),
            expectedPrice: testRun.expectedPrice
        ))
    }
    testRuns.appendAll(reversedRuns)
    for testRun in testRuns {
        if snapshot != getCurrentBlockHeight() {
            Test.reset(to: snapshot)
        }
        let info = createAggregator(
            ofToken: Type<@FlowToken.Vault>(),
            oracleCount: testRun.prices.length,
            maxSpread: 10000.0,
            baseTolerance: 10000.0,
            driftExpansionRate: 10000.0,
            priceHistorySize: 0,
            priceHistoryInterval: 0.0,
            maxPriceHistoryAge: 0.0,
            minimumPriceHistory: 0,
            unitOfAccount: Type<@MOET.Vault>(),
        )
        set_prices(info: info, prices: testRun.prices, forToken: Type<@FlowToken.Vault>())
        var price = oracleAggregatorPrice(
            storageID: info.aggregatorStorageID,
            ofToken: Type<@FlowToken.Vault>()
        )
        if price != testRun.expectedPrice {
            log(testRun)
            logFailEvents()
            Test.fail(message: "invalid price")
        }
    }
}

access(all) struct TestRunSpread {
    access(all) let maxSpread: UFix64
    access(all) let prices: [UFix64]
    access(all) let expectedPrice: UFix64?

    init(maxSpread: UFix64, prices: [UFix64], expectedPrice: UFix64?) {
        self.maxSpread = maxSpread
        self.prices = prices
        self.expectedPrice = expectedPrice
    }
}

access(all) fun test_spread() {
    // testRuns: maxSpread rejects when (max - min) / min > maxSpread
    let testRuns = [
    // Spread 1.0 (100%) > maxSpread 0.9: reject
    TestRunSpread(
        maxSpread: 0.9,
        prices: [1.0, 2.0],
        expectedPrice: nil,
    ),
    // Spread from 1.0 to 2.0 still exceeds 0.9: reject
    TestRunSpread(
        maxSpread: 0.9,
        prices: [1.0, 1.5, 2.0],
        expectedPrice: nil,
    ),
    // Same spread [1.0, 2.0, 1.0]: reject
    TestRunSpread(
        maxSpread: 0.9,
        prices: [1.0, 2.0, 1.0],
        expectedPrice: nil,
    ),
    // All oracles agree: within any spread, accept 1.0
    TestRunSpread(
        maxSpread: 0.9,
        prices: [1.0, 1.0, 1.0, 1.0],
        expectedPrice: 1.0,
    ),
    // maxSpread 0 = no tolerance; tiny diff 1.0001 vs 1.0: reject
    TestRunSpread(
        maxSpread: 0.0,
        prices: [1.0, 1.0001],
        expectedPrice: nil,
    ),
    // Same with three oracles: reject
    TestRunSpread(
        maxSpread: 0.0,
        prices: [1.0, 1.0001, 1.0],
        expectedPrice: nil,
    ),
    // Very loose maxSpread: accept average 1.5
    TestRunSpread(
        maxSpread: 10000.0,
        prices: [1.0, 2.0],
        expectedPrice: 1.5,
    ),
    // Loose spread, three oracles: accept median/average 1.5
    TestRunSpread(
        maxSpread: 10000.0,
        prices: [1.0, 1.5, 2.0],
        expectedPrice: 1.5,
    )]
    let reversedRuns: [TestRunSpread] = []
    for testRun in testRuns {
        reversedRuns.append(TestRunSpread(
            maxSpread: testRun.maxSpread,
            prices: testRun.prices.reverse(),
            expectedPrice: testRun.expectedPrice,
        ))
    }
    testRuns.appendAll(reversedRuns)
    for testRun in testRuns {
        if snapshot != getCurrentBlockHeight() {
            Test.reset(to: snapshot)
        }
        let info = createAggregator(
            ofToken: Type<@FlowToken.Vault>(),
            oracleCount: testRun.prices.length,
            maxSpread: testRun.maxSpread,
            baseTolerance: 10000.0,
            driftExpansionRate: 10000.0,
            priceHistorySize: 0,
            priceHistoryInterval: 0.0,
            maxPriceHistoryAge: 0.0,
            minimumPriceHistory: 0,
            unitOfAccount: Type<@MOET.Vault>(),
        )
        set_prices(info: info, prices: testRun.prices, forToken: Type<@FlowToken.Vault>())
        var price = oracleAggregatorPrice(
            storageID: info.aggregatorStorageID,
            ofToken: Type<@FlowToken.Vault>()
        )
        if price != testRun.expectedPrice {
            log(testRun)
            logFailEvents()
            log(price)
            Test.assertEqual(testRun.expectedPrice, price)
        }
    }
}

access(all) struct TestRunHistory {
    access(all) let baseTolerance: UFix64
    access(all) let driftExpansionRate: UFix64
    access(all) let priceHistory: [UFix64]
    access(all) let priceHistoryDelay: Fix64
    access(all) let isHistoryStable: Bool

    init(
        baseTolerance: UFix64,
        driftExpansionRate: UFix64,
        priceHistory: [UFix64],
        priceHistoryDelay: Fix64,
        isHistoryStable: Bool,
    ) {
        self.baseTolerance = baseTolerance
        self.driftExpansionRate = driftExpansionRate
        self.priceHistory = priceHistory
        self.priceHistoryDelay = priceHistoryDelay
        self.isHistoryStable = isHistoryStable
    }
}

access(all) fun test_history() {
    // testRuns: price history stability (baseTolerance + driftExpansionRate over time)
    let testRuns = [
    // Single price point: always stable
    TestRunHistory(
        baseTolerance: 0.0,
        driftExpansionRate: 0.0,
        priceHistory: [1.0],
        priceHistoryDelay: 60.0,
        isHistoryStable: true,
    ),
    // baseTolerance 1.0 allows 2x jump (1.0 -> 2.0): stable
    TestRunHistory(
        baseTolerance: 1.0,
        driftExpansionRate: 0.0,
        priceHistory: [1.0, 2.0],
        priceHistoryDelay: 60.0,
        isHistoryStable: true,
    ),
    // baseTolerance 0.95 too tight for 1.0 -> 2.0 (100% move): unstable
    TestRunHistory(
        baseTolerance: 0.95,
        driftExpansionRate: 0.0,
        priceHistory: [1.0, 2.0],
        priceHistoryDelay: 60.0,
        isHistoryStable: false,
    ),
    // Third point 2.1 deviates from history [1.0, 2.0] beyond tolerance: unstable
    TestRunHistory(
        baseTolerance: 1.0,
        driftExpansionRate: 0.0,
        priceHistory: [1.0, 2.0, 2.1],
        priceHistoryDelay: 60.0,
        isHistoryStable: false,
    ),
    // History [2, 1, 3, 2]: within tolerance band from previous: stable
    TestRunHistory(
        baseTolerance: 1.0,
        driftExpansionRate: 0.0,
        priceHistory: [2.0, 1.0, 3.0, 2.0],
        priceHistoryDelay: 60.0,
        isHistoryStable: true,
    ),
    // Small drift 100 -> 100.2 over 6 steps; very tight baseTolerance (0.1%): unstable
    TestRunHistory(
        baseTolerance: 0.1 / 100.0,
        driftExpansionRate: 0.0,
        priceHistory: [100.0, 100.1, 100.1, 100.1, 100.1, 100.2],
        priceHistoryDelay: 60.0,
        isHistoryStable: false,
    ),
    // driftExpansionRate 1.0 allows linear drift 1 -> 2 -> 3: stable
    TestRunHistory(
        baseTolerance: 0.0,
        driftExpansionRate: 1.0,
        priceHistory: [1.0, 2.0, 3.0],
        priceHistoryDelay: 60.0,
        isHistoryStable: true,
    ),
    // 3.1 exceeds allowed drift from 3.0: unstable
    TestRunHistory(
        baseTolerance: 0.0,
        driftExpansionRate: 1.0,
        priceHistory: [1.0, 2.0, 3.1],
        priceHistoryDelay: 60.0,
        isHistoryStable: false,
    ),
    // History [2, 1, 3, 2] with drift allowed: stable
    TestRunHistory(
        baseTolerance: 0.0,
        driftExpansionRate: 1.0,
        priceHistory: [2.0 , 1.0, 3.0, 2.0],
        priceHistoryDelay: 60.0,
        isHistoryStable: true,
    ),
    // driftExpansionRate 0.1 allows 0.1 steps 1.0 -> 1.1 -> 1.2 -> 1.3: stable
    TestRunHistory(
        baseTolerance: 0.0,
        driftExpansionRate: 0.1,
        priceHistory: [1.0, 1.1, 1.2, 1.3],
        priceHistoryDelay: 60.0,
        isHistoryStable: true,
    ),
    // baseTolerance 0.2 + drift 0.1: 1.0 -> 1.3 within band: stable
    TestRunHistory(
        baseTolerance: 0.2,
        driftExpansionRate: 0.1,
        priceHistory: [1.0, 1.3],
        priceHistoryDelay: 60.0,
        isHistoryStable: true,
    ),
    // 1.31 exceeds baseTolerance 0.2 + drift from 1.0: unstable
    TestRunHistory(
        baseTolerance: 0.2,
        driftExpansionRate: 0.1,
        priceHistory: [1.0, 1.31],
        priceHistoryDelay: 60.0,
        isHistoryStable: false,
    )]
    let reversedRuns: [TestRunHistory] = []
    for testRun in testRuns {
        reversedRuns.append(TestRunHistory(
            baseTolerance: testRun.baseTolerance,
            driftExpansionRate: testRun.driftExpansionRate,
            priceHistory: testRun.priceHistory.reverse(),
            priceHistoryDelay: testRun.priceHistoryDelay,
            isHistoryStable: testRun.isHistoryStable,
        ))
    }
    testRuns.appendAll(reversedRuns)
    for testRun in testRuns {
        if snapshot != getCurrentBlockHeight() {
            Test.reset(to: snapshot)
        }
        let info = createAggregator(
            ofToken: Type<@FlowToken.Vault>(),
            oracleCount: 1,
            maxSpread: 10000.0,
            baseTolerance: testRun.baseTolerance,
            driftExpansionRate: testRun.driftExpansionRate,
            priceHistorySize: UInt8(testRun.priceHistory.length),
            priceHistoryInterval: UFix64(testRun.priceHistoryDelay - 1.0), // allow some jitter
            maxPriceHistoryAge: 600.0, // 10 minutes
            minimumPriceHistory: 0,
            unitOfAccount: Type<@MOET.Vault>(),
        )
        for price in testRun.priceHistory {
            setMultiMockOraclePrice(
                storageID: info.mockOracleStorageIDs[0],
                forToken: Type<@FlowToken.Vault>(),
                price: price,
            )
            Test.moveTime(by: testRun.priceHistoryDelay)
            var price = oracleAggregatorPrice(
                storageID: info.aggregatorStorageID,
                ofToken: Type<@FlowToken.Vault>()
            )
        }
        // make sure prices are correctly recorded
        let priceHistory = oracleAggregatorPriceHistory(storageID: info.aggregatorStorageID)
        Test.assert(testRun.priceHistory.length == priceHistory.length, message: "price history length should be \(testRun.priceHistory.length), got \(priceHistory.length)")
        var i = 0
        for price in testRun.priceHistory {
            Test.assertEqual(price, priceHistory[i].price)
            i = i + 1
        }

        var price = oracleAggregatorPrice(
            storageID: info.aggregatorStorageID,
            ofToken: Type<@FlowToken.Vault>()
        )
        let priceIsStable = price != nil
        if priceIsStable != testRun.isHistoryStable {
            log(testRun)
            log(price)
            logFailEvents()
            Test.fail(message: "invalid price")
        }
    }
}

access(self) fun test_incomplete_price_history() {
    let priceHistory = [1.0, nil, nil, 4.0]
    let info = createAggregator(
        ofToken: Type<@FlowToken.Vault>(),
        oracleCount: 1,
        maxSpread: 10000.0,
        baseTolerance: 0.0,
        driftExpansionRate: 1.0,
        priceHistorySize: UInt8(priceHistory.length),
        priceHistoryInterval: 59.0, // allow some jitter
        maxPriceHistoryAge: 600.0, // 10 minutes
        minimumPriceHistory: 0,
        unitOfAccount: Type<@MOET.Vault>(),
    )
    Test.moveTime(by: 10.0)
    for price in priceHistory {
        setMultiMockOraclePrice(
            storageID: info.mockOracleStorageIDs[0],
            forToken: Type<@FlowToken.Vault>(),
            price: price,
        )
        Test.moveTime(by: 60.0)
        var price = oracleAggregatorPrice(
            storageID: info.aggregatorStorageID,
            ofToken: Type<@FlowToken.Vault>()
        )
    }
    var price = oracleAggregatorPrice(
        storageID: info.aggregatorStorageID,
        ofToken: Type<@FlowToken.Vault>()
    )
    let priceIsStable = price != nil
    Test.assert(priceIsStable, message: "price should be stable")
}

access(self) fun test_old_price_history() {
    let priceHistory = [1.0, nil, nil, 40.0]
    let info = createAggregator(
        ofToken: Type<@FlowToken.Vault>(),
        oracleCount: 1,
        maxSpread: 10000.0,
        baseTolerance: 0.0,
        driftExpansionRate: 1.0,
        priceHistorySize: UInt8(priceHistory.length),
        priceHistoryInterval: 59.0, // allow some jitter
        maxPriceHistoryAge: 150.0,
        minimumPriceHistory: 0,
        unitOfAccount: Type<@MOET.Vault>(),
    )
    for price in priceHistory {
        setMultiMockOraclePrice(
            storageID: info.mockOracleStorageIDs[0],
            forToken: Type<@FlowToken.Vault>(),
            price: price,
        )
        Test.moveTime(by: 60.0)
        var price = oracleAggregatorPrice(
            storageID: info.aggregatorStorageID,
            ofToken: Type<@FlowToken.Vault>()
        )
    }
    var price = oracleAggregatorPrice(
        storageID: info.aggregatorStorageID,
        ofToken: Type<@FlowToken.Vault>()
    )
    let priceIsStable = price != nil
    Test.assert(priceIsStable, message: "price should be stable")
}

access(all) fun test_minimum_price_history() {
    let info = createAggregator(
        ofToken: Type<@FlowToken.Vault>(),
        oracleCount: 1,
        maxSpread: 10000.0,
        baseTolerance: 10000.0,
        driftExpansionRate: 10000.0,
        priceHistorySize: 10,
        priceHistoryInterval: 59.0,
        maxPriceHistoryAge: 600.0, // 20 minutes
        minimumPriceHistory: 5,
        unitOfAccount: Type<@MOET.Vault>(),
    )
    setMultiMockOraclePrice(
        storageID: info.mockOracleStorageIDs[0],
        forToken: Type<@FlowToken.Vault>(),
        price: 1.0,
    )
    var _ = oracleAggregatorPrice(
        storageID: info.aggregatorStorageID,
        ofToken: Type<@FlowToken.Vault>()
    )
    var i = 0
    while i < 15 {
        var price = oracleAggregatorPrice(
            storageID: info.aggregatorStorageID,
            ofToken: Type<@FlowToken.Vault>()
        )
        Test.moveTime(by: 60.0)
        // 0, 1, 2, 3 are not enough, 4 is enough
        if i <= 3 {
            Test.assert(price == nil, message: "price history should not have enough entries")
        } else {
            Test.assert(price == 1.0, message: "price history should have enough entries")
        }
        i = i + 1
    }
}

access(all) fun test_events() {
    let info = createAggregator(
        ofToken: Type<@FlowToken.Vault>(),
        oracleCount: 2,
        maxSpread: 1.0,
        baseTolerance: 1.0,
        driftExpansionRate: 1.0,
        priceHistorySize: 1,
        priceHistoryInterval: 60.0,
        maxPriceHistoryAge: 600.0,
        minimumPriceHistory: 0,
        unitOfAccount: Type<@MOET.Vault>(),
    )
    // 1. PriceNotAvailable: one oracle returns nil
    setMultiMockOraclePrice(
        storageID: info.mockOracleStorageIDs[0],
        forToken: Type<@FlowToken.Vault>(),
        price: 1.0,
    )
    setMultiMockOraclePrice(
        storageID: info.mockOracleStorageIDs[1],
        forToken: Type<@FlowToken.Vault>(),
        price: nil,
    )
    var _ = oracleAggregatorPrice(
        storageID: info.aggregatorStorageID,
        ofToken: Type<@FlowToken.Vault>()
    )
    let notAvailEvents = Test.eventsOfType(Type<FlowPriceOracleAggregatorv1.PriceNotAvailable>())
    Test.assert(notAvailEvents.length == 1, message: "expected exactly one PriceNotAvailable event")
    let notAvailData = notAvailEvents[0] as! FlowPriceOracleAggregatorv1.PriceNotAvailable
    Test.assert(notAvailData.oracleType == Type<MultiMockOracle.PriceOracle>(), message: "oracleType should be MultiMockOracle.PriceOracle")

    // 2. PriceNotWithinSpreadTolerance: spread between oracles exceeds maxSpread
    setMultiMockOraclePrice(
        storageID: info.mockOracleStorageIDs[1],
        forToken: Type<@FlowToken.Vault>(),
        price: 3.0,
    )
    _ = oracleAggregatorPrice(
        storageID: info.aggregatorStorageID,
        ofToken: Type<@FlowToken.Vault>()
    )
    let spreadEvents = Test.eventsOfType(Type<FlowPriceOracleAggregatorv1.PriceNotWithinSpreadTolerance>())
    Test.assert(spreadEvents.length == 1, message: "expected exactly one PriceNotWithinSpreadTolerance event")
    let spreadData = spreadEvents[0] as! FlowPriceOracleAggregatorv1.PriceNotWithinSpreadTolerance
    Test.assert(spreadData.spread >= 2.0, message: "spread should be greater than 2.0")
    Test.assert(spreadData.maxAllowedSpread >= 1.0, message: "maxAllowedSpread should be greater than 1.0")

    // 3. PriceNotWithinHistoryTolerance: current price deviates too much from history
    setMultiMockOraclePrice(
        storageID: info.mockOracleStorageIDs[1],
        forToken: Type<@FlowToken.Vault>(),
        price: 1.0,
    )
    _ = oracleAggregatorPrice(
        storageID: info.aggregatorStorageID,
        ofToken: Type<@FlowToken.Vault>()
    )
    // now history is 1.0
    Test.moveTime(by: 50.0)
    setMultiMockOraclePrice(
        storageID: info.mockOracleStorageIDs[0],
        forToken: Type<@FlowToken.Vault>(),
        price: 3.0,
    )
    setMultiMockOraclePrice(
        storageID: info.mockOracleStorageIDs[1],
        forToken: Type<@FlowToken.Vault>(),
        price: 3.0,
    )
    _ = oracleAggregatorPrice(
        storageID: info.aggregatorStorageID,
        ofToken: Type<@FlowToken.Vault>()
    )
    let historyEvents = Test.eventsOfType(Type<FlowPriceOracleAggregatorv1.PriceNotWithinHistoryTolerance>())
    Test.assert(historyEvents.length == 1, message: "expected exactly one PriceNotWithinHistoryTolerance event got \(historyEvents.length)")
    let historyData = historyEvents[0] as! FlowPriceOracleAggregatorv1.PriceNotWithinHistoryTolerance
    Test.assert(historyData.relativeDiff >= 2.0, message: "relativeDiff should be greater than 2.0 got \(historyData.relativeDiff)")
    let deltaTInRange = historyData.deltaTMinutes >= 50.0 / 60.0 && historyData.deltaTMinutes <= 1.0
    Test.assert(deltaTInRange, message: "deltaTMinutes should be between \(50.0 / 60.0) and 1.0 got \(historyData.deltaTMinutes)")
    let minMaxAllowedRelativeDiff = 1.0 + 1.0 * (50.0 / 60.0)
    let relativeDiffInRange = historyData.relativeDiff >= minMaxAllowedRelativeDiff && historyData.relativeDiff <= 2.0
    Test.assert(relativeDiffInRange, message: "relativeDiff should be between \(minMaxAllowedRelativeDiff) and 2.0 got \(historyData.relativeDiff)")
}

access(all) fun test_cron_job() {
    let info = createAggregatorWithCron(
        signer: signer,
        ofToken: Type<@FlowToken.Vault>(),
        oracleCount: 1,
        maxSpread: 10000.0,
        baseTolerance: 10000.0,
        driftExpansionRate: 10000.0,
        priceHistorySize: 5,
        priceHistoryInterval: 59.0, // allow some jitter
        maxPriceHistoryAge: 600.0, // 10 minutes
        minimumPriceHistory: 0,
        unitOfAccount: Type<@MOET.Vault>(),
        cronExpression: "* * * * *", // every minute
        cronHandlerStoragePath: StoragePath(identifier: "cronHandler")!,
        keeperExecutionEffort: 7500,
        executorExecutionEffort: 2500,
        aggregatorCronHandlerStoragePath: StoragePath(identifier: "aggregatorCronHandler")!,
    )
    setMultiMockOraclePrice(
        storageID: info.mockOracleStorageIDs[0],
        forToken: Type<@FlowToken.Vault>(),
        price: 1.0,
    )
    var i = 0;
    Test.moveTime(by: 30.0)
    while i < 5 {
        let history = oracleAggregatorPriceHistory(storageID: info.aggregatorStorageID)
        Test.assert(history.length == i + 1, message: "history length should be \(i + 1), got \(history.length)")
        let timeDelta = Fix64(getCurrentBlock().timestamp) - Fix64(history[i].timestamp)
        Test.assert(timeDelta < 30.0, message: "timestamp mismatch")
        i = i + 1
        Test.moveTime(by: 60.0)
    }
}

access(self) fun set_prices(info: CreateAggregatorInfo, prices: [UFix64?], forToken: Type) {
    var i = 0
    let txs: [Test.Transaction] = []
    for p in prices {
        let tx = setMultiMockOraclePriceTx(
            storageID: info.mockOracleStorageIDs[i],
            forToken: forToken,
            price: p,
        )
        txs.append(tx)
        i = i + 1
    }
    let res = Test.executeTransactions(txs)
    for r in res {
        Test.expect(r, Test.beSucceeded())
    }
}

access(self) fun logFailEvents() {
    let failureEvents = [
        Type<FlowPriceOracleAggregatorv1.PriceNotAvailable>(),
        Type<FlowPriceOracleAggregatorv1.PriceNotWithinSpreadTolerance>(),
        Type<FlowPriceOracleAggregatorv1.PriceNotWithinHistoryTolerance>()
    ]
    for eventType in failureEvents {
        let events = Test.eventsOfType(eventType)
        if events.length > 0 {
            log(eventType)
            log(events)
        }
    }
}
