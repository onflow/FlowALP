import Test
import BlockchainHelpers

import "FlowOracleAggregatorv1"
import "DeFiActions"
import "FlowToken"
import "MOET"
import "MultiMockOracle"
import "test_helpers.cdc"
import "test_helpers_oracle_aggregator.cdc"

access(all) var snapshot: UInt64 = 0
// access(all) var aggregatorID: UInt64 = 0
// access(all) var aggregatorStruct: FlowOracleAggregatorV1.PriceOracleAggregatorStruct? = nil

access(all) fun setup() {
    deployContracts()
    snapshot = getCurrentBlockHeight()
}

access(all) fun beforeEach() {
    if snapshot != getCurrentBlockHeight() {
        Test.reset(to: snapshot)
    }
}

access(all) fun test_single_oracle() {
    let info = createAggregator(
        oracleCount: 1,
        maxSpread: 0.0,
        maxGradient: 0.0,
        priceHistorySize: 0,
        priceHistoryInterval: 0.0,
        unitOfAccount: Type<@MOET.Vault>()
    )
    let prices = [1.0, 0.0001, 1337.0]
    for p in prices {
        setPrice(
            priceOracleStorageID: info.oracleIDs[0],
            forToken: Type<@FlowToken.Vault>(),
            price: p,
        )
        var price = getPrice(
            uuid: info.aggregatorID,
            ofToken: Type<@FlowToken.Vault>()
        )
        Test.assert(price != nil, message: "Price should not be nil")
        Test.assertEqual(price!, p)
    }
}

access(all) fun test_multiple_oracles() {
    let oracleCounts = [1, 2, 3, 4, 5, 6]
    for oracleCount in oracleCounts {
        let info = createAggregator(
            oracleCount: oracleCount,
            maxSpread: 0.0,
            maxGradient: 0.0,
            priceHistorySize: 0,
            priceHistoryInterval: 0.0,
            unitOfAccount: Type<@MOET.Vault>()
        )
        let prices = [1.0, 0.0001, 1337.0]
        for p in prices {
            for oracleID in info.oracleIDs {
                setPrice(
                    priceOracleStorageID: oracleID,
                    forToken: Type<@FlowToken.Vault>(),
                    price: p,
                )
            }
            var price = getPrice(
                uuid: info.aggregatorID,
                ofToken: Type<@FlowToken.Vault>()
            )
            Test.assert(price != nil, message: "Price should not be nil")
            Test.assertEqual(price!, p)
        }
    }
}

access(all) struct TestRunAveragePrice {
    access(all) let prices: [UFix64]
    access(all) let expectedPrice: UFix64?

    init(prices: [UFix64], expectedPrice: UFix64?) {
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
    )]
    testRuns.appendAll(testRuns.reverse())
    for testRun in testRuns {
        let info = createAggregator(
            oracleCount: testRun.prices.length,
            maxSpread: UFix64.max,
            maxGradient: UFix64.max,
            priceHistorySize: 0,
            priceHistoryInterval: 0.0,
            unitOfAccount: Type<@MOET.Vault>()
        )
        set_prices(info: info, prices: testRun.prices)
        var price = getPrice(
            uuid: info.aggregatorID,
            ofToken: Type<@FlowToken.Vault>()
        )
        if price != testRun.expectedPrice {
            log(testRun)
            log_fail_events()
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
    let testRuns = [TestRunSpread(
        maxSpread: 0.9,
        prices: [1.0, 2.0],
        expectedPrice: nil,
    ), TestRunSpread(
        maxSpread: 0.9,
        prices: [1.0, 1.5, 2.0],
        expectedPrice: nil,
    ), TestRunSpread(
        maxSpread: 0.9,
        prices: [1.0, 2.0, 1.0],
        expectedPrice: nil,
    ), TestRunSpread(
        maxSpread: 0.9,
        prices: [1.0, 1.0, 1.0, 1.0],
        expectedPrice: 1.0,
    ), TestRunSpread(
        maxSpread: 0.0,
        prices: [1.0, 1.0001],
        expectedPrice: nil,
    ), TestRunSpread(
        maxSpread: 0.0,
        prices: [1.0, 1.0001, 1.0],
        expectedPrice: nil,
    ), TestRunSpread(
        maxSpread: 1.0,
        prices: [1.0, 2.0],
        expectedPrice: 1.5,
    ), TestRunSpread(
        maxSpread: 1.0,
        prices: [1.0, 1.5, 2.0],
        expectedPrice: 1.5,
    )]
    testRuns.appendAll(testRuns.reverse())
    for testRun in testRuns {
        let info = createAggregator(
            oracleCount: testRun.prices.length,
            maxSpread: testRun.maxSpread,
            maxGradient: UFix64.max,
            priceHistorySize: 0,
            priceHistoryInterval: 0.0,
            unitOfAccount: Type<@MOET.Vault>()
        )
        set_prices(info: info, prices: testRun.prices)
        var price = getPrice(
            uuid: info.aggregatorID,
            ofToken: Type<@FlowToken.Vault>()
        )
        if price != testRun.expectedPrice {
            log(testRun)
            log_fail_events()
            Test.fail(message: "invalid price")
        }
    }
}

access(all) fun test_gradient() {
    Test.assert(false, message: "not implemented")
}

access(self) fun set_prices(info: CreateAggregatorInfo, prices: [UFix64]) {
    var i = 0
    for p in prices {
        setPrice(
            priceOracleStorageID: info.oracleIDs[i],
            forToken: Type<@FlowToken.Vault>(),
            price: p,
        )
        i = i + 1
    }
}

access(self) fun log_fail_events() {
    let failureEvents = [
        Type<FlowOracleAggregatorv1.PriceNotAvailable>(),
        Type<FlowOracleAggregatorv1.PriceNotWithinSpreadTolerance>(),
        Type<FlowOracleAggregatorv1.PriceNotStable>()
    ]
    for eventType in failureEvents {
        let events = Test.eventsOfType(eventType)
        if events.length > 0 {
            log(eventType)
            log(events)
        }
    }
}
