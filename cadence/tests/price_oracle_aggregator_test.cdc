import Test
import BlockchainHelpers

import "FlowPriceOracleAggregatorv1"
import "FlowToken"
import "MOET"
import "MultiMockOracle"
import "test_helpers.cdc"
import "test_helpers_price_oracle_aggregator.cdc"

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
        signer: signer,
        ofToken: Type<@FlowToken.Vault>(),
        oracleCount: 1,
        maxSpread: 0.0,
        maxGradient: 0.0,
        priceHistorySize: 0,
        priceHistoryInterval: 0.0,
        maxPriceHistoryAge: 0.0,
        unitOfAccount: Type<@MOET.Vault>(),
        cronExpression: "0 0 1 1 *",
        cronHandlerStoragePath: /storage/cronHandler,
        keeperExecutionEffort: 7500,
        executorExecutionEffort: 2500,
        aggregatorCronHandlerStoragePath: /storage/aggregatorCronHandler
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
        Test.assertEqual(price, p)
    }
}

access(all) fun test_multiple_oracles() {
    let oracleCounts = [1, 2, 3, 4, 5, 6]
    for oracleCount in oracleCounts {
        if snapshot != getCurrentBlockHeight() {
            Test.reset(to: snapshot)
        }
        let info = createAggregator(
            signer: signer,
            ofToken: Type<@FlowToken.Vault>(),
            oracleCount: oracleCount,
            maxSpread: 0.0,
            maxGradient: 0.0,
            priceHistorySize: 0,
            priceHistoryInterval: 0.0,
            maxPriceHistoryAge: 0.0,
            unitOfAccount: Type<@MOET.Vault>(),
            cronExpression: "0 0 1 1 *",
            cronHandlerStoragePath: /storage/cronHandler,
            keeperExecutionEffort: 7500,
            executorExecutionEffort: 2500,
            aggregatorCronHandlerStoragePath: /storage/aggregatorCronHandler
        )
        let prices: [UFix64?] = [1.0, 0.0001, 1337.0]
        for p in prices {
            for oracleID in info.mockOracleStorageIDs {
                setMultiMockOraclePrice(
                    storageID: oracleID,
                    forToken: Type<@FlowToken.Vault>(),
                    price: p,
                )
            }
            var price = oracleAggregatorPrice(
                storageID: info.aggregatorStorageID,
                ofToken: Type<@FlowToken.Vault>()
            )
            Test.assertEqual(price, p)
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
            signer: signer,
            ofToken: Type<@FlowToken.Vault>(),
            oracleCount: testRun.prices.length,
            maxSpread: UFix64.max,
            maxGradient: UFix64.max,
            priceHistorySize: 0,
            priceHistoryInterval: 0.0,
            maxPriceHistoryAge: 0.0,
            unitOfAccount: Type<@MOET.Vault>(),
            cronExpression: "0 0 1 1 *",
            cronHandlerStoragePath: /storage/cronHandler,
            keeperExecutionEffort: 7500,
            executorExecutionEffort: 2500,
            aggregatorCronHandlerStoragePath: /storage/aggregatorCronHandler
        )
        set_prices(info: info, prices: testRun.prices)
        var price = oracleAggregatorPrice(
            storageID: info.aggregatorStorageID,
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
            signer: signer,
            ofToken: Type<@FlowToken.Vault>(),
            oracleCount: testRun.prices.length,
            maxSpread: testRun.maxSpread,
            maxGradient: UFix64.max,
            priceHistorySize: 0,
            priceHistoryInterval: 0.0,
            maxPriceHistoryAge: 0.0,
            unitOfAccount: Type<@MOET.Vault>(),
            cronExpression: "0 0 1 1 *",
            cronHandlerStoragePath: /storage/cronHandler,
            keeperExecutionEffort: 7500,
            executorExecutionEffort: 2500,
            aggregatorCronHandlerStoragePath: /storage/aggregatorCronHandler
        )
        set_prices(info: info, prices: testRun.prices)
        var price = oracleAggregatorPrice(
            storageID: info.aggregatorStorageID,
            ofToken: Type<@FlowToken.Vault>()
        )
        if price != testRun.expectedPrice {
            log(testRun)
            log_fail_events()
            Test.fail(message: "invalid price")
        }
    }
}

access(all) struct TestRunGradient {
    access(all) let maxGradient: UFix64
    access(all) let priceHistory: [UFix64]
    access(all) let priceHistoryDelay: Fix64
    access(all) let isGradientStable: Bool

    init(maxGradient: UFix64, priceHistory: [UFix64], priceHistoryDelay: Fix64, isGradientStable: Bool) {
        self.maxGradient = maxGradient
        self.priceHistory = priceHistory
        self.priceHistoryDelay = priceHistoryDelay
        self.isGradientStable = isGradientStable
    }
}

access(all) fun test_gradient() {
    let testRuns = [
    TestRunGradient(
        maxGradient: 0.0,
        priceHistory: [1.0],
        priceHistoryDelay: 60.0,
        isGradientStable: true,
    ),TestRunGradient(
        maxGradient: 100.0,
        priceHistory: [1.0, 2.0],
        priceHistoryDelay: 60.0,
        isGradientStable: true,
    ),TestRunGradient(
        maxGradient: 95.0,
        priceHistory: [1.0, 2.0],
        priceHistoryDelay: 60.0,
        isGradientStable: false,
    ),TestRunGradient(
        maxGradient: 100.0,
        priceHistory: [1.0, 2.0, 3.1],
        priceHistoryDelay: 60.0,
        isGradientStable: false,
    ),TestRunGradient(
        maxGradient: 100.0,
        priceHistory: [2.0, 1.0, 3.0, 2.0],
        priceHistoryDelay: 60.0,
        isGradientStable: true,
    ),TestRunGradient(
        maxGradient: 0.1,
        priceHistory: [100.0, 100.1, 100.1, 100.1, 100.1, 100.2],
        priceHistoryDelay: 60.0,
        isGradientStable: true,
    )]
    let reversedRuns: [TestRunGradient] = []
    for testRun in testRuns {
        reversedRuns.append(TestRunGradient(
            maxGradient: testRun.maxGradient,
            priceHistory: testRun.priceHistory.reverse(),
            priceHistoryDelay: testRun.priceHistoryDelay,
            isGradientStable: testRun.isGradientStable,
        ))
    }
    testRuns.appendAll(reversedRuns)
    for testRun in testRuns {
        if snapshot != getCurrentBlockHeight() {
            Test.reset(to: snapshot)
        }
        let info = createAggregator(
            signer: signer,
            ofToken: Type<@FlowToken.Vault>(),
            oracleCount: 1,
            maxSpread: UFix64.max,
            maxGradient: testRun.maxGradient,
            priceHistorySize: testRun.priceHistory.length,
            priceHistoryInterval: 59.0, // allow some jitter
            maxPriceHistoryAge: 600.0, // 10 minutes
            unitOfAccount: Type<@MOET.Vault>(),
            cronExpression: "* * 1 1 *",
            cronHandlerStoragePath: /storage/cronHandler,
            keeperExecutionEffort: 7500,
            executorExecutionEffort: 2500,
            aggregatorCronHandlerStoragePath: /storage/aggregatorCronHandler
        )
        // need to move time to avoid race condition of the cron job
        Test.moveTime(by: 10.0)
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
        Test.assertEqual(testRun.priceHistory.length, priceHistory.length)
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
        if priceIsStable != testRun.isGradientStable {
            log(testRun)
            log_fail_events()
            Test.fail(message: "invalid price")
        }
    }
}

access(self) fun test_gradient_incomplete_price_history() {
    let priceHistory = [1.0, nil, nil, 4.0]
    let info = createAggregator(
        signer: signer,
        ofToken: Type<@FlowToken.Vault>(),
        oracleCount: 1,
        maxSpread: UFix64.max,
        maxGradient: 100.0,
        priceHistorySize: priceHistory.length,
        priceHistoryInterval: 59.0, // allow some jitter
        maxPriceHistoryAge: 600.0, // 10 minutes
        unitOfAccount: Type<@MOET.Vault>(),
        cronExpression: "* * 1 1 *",
        cronHandlerStoragePath: /storage/cronHandler,
        keeperExecutionEffort: 7500,
        executorExecutionEffort: 2500,
        aggregatorCronHandlerStoragePath: /storage/aggregatorCronHandler
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
    Test.assertEqual(priceIsStable, true)
}

access(self) fun test_gradient_old_price_history() {
    let priceHistory = [1.0, nil, nil, 40.0]
    let info = createAggregator(
        signer: signer,
        ofToken: Type<@FlowToken.Vault>(),
        oracleCount: 1,
        maxSpread: UFix64.max,
        maxGradient: 1.0,
        priceHistorySize: priceHistory.length,
        priceHistoryInterval: 59.0, // allow some jitter
        maxPriceHistoryAge: 150.0,
        unitOfAccount: Type<@MOET.Vault>(),
        cronExpression: "* * 1 1 *",
        cronHandlerStoragePath: /storage/cronHandler,
        keeperExecutionEffort: 7500,
        executorExecutionEffort: 2500,
        aggregatorCronHandlerStoragePath: /storage/aggregatorCronHandler
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
    Test.assertEqual(priceIsStable, true)
}

access(self) fun set_prices(info: CreateAggregatorInfo, prices: [UFix64?]) {
    var i = 0
    for p in prices {
        setMultiMockOraclePrice(
            storageID: info.mockOracleStorageIDs[i],
            forToken: Type<@FlowToken.Vault>(),
            price: p,
        )
        i = i + 1
    }
}

access(self) fun log_fail_events() {
    let failureEvents = [
        Type<FlowPriceOracleAggregatorv1.PriceNotAvailable>(),
        Type<FlowPriceOracleAggregatorv1.PriceNotWithinSpreadTolerance>(),
        Type<FlowPriceOracleAggregatorv1.PriceNotWithinGradientTolerance>()
    ]
    for eventType in failureEvents {
        let events = Test.eventsOfType(eventType)
        if events.length > 0 {
            log(eventType)
            log(events)
        }
    }
}
