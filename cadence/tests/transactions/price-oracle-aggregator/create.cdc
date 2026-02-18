import "DeFiActions"
import "FlowPriceOracleAggregatorv1"
import "FlowTransactionScheduler"
import "FlowTransactionSchedulerUtils"
import "FungibleToken"
import "FlowToken"
import "FlowFees"
import "FlowCron"
import "MultiMockOracle"
import "MOET"

transaction(
    ofToken: Type,
    oracleCount: Int,
    maxSpread: UFix64,
    maxGradient: UFix64,
    priceHistorySize: Int,
    priceHistoryInterval: UFix64,
    maxPriceHistoryAge: UFix64,
    unitOfAccount: Type,
) {
    let oracles: [{DeFiActions.PriceOracle}]

    prepare() {
        self.oracles = []
        var i = 0
        while i < oracleCount {
            self.oracles.append(MultiMockOracle.createPriceOracle(unitOfAccountType: unitOfAccount))
            i = i + 1
        }
    }

    execute {
        let _ = FlowPriceOracleAggregatorv1.createPriceOracleAggregatorStorage(
            ofToken: ofToken,
            oracles: self.oracles,
            maxSpread: maxSpread,
            maxGradient: maxGradient,
            priceHistorySize: priceHistorySize,
            priceHistoryInterval: priceHistoryInterval,
            maxPriceHistoryAge: maxPriceHistoryAge,
            unitOfAccount: unitOfAccount
        )
    }
}