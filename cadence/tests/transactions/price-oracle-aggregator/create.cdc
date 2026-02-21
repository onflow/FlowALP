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
    baseTolerance: UFix64,
    driftExpansionRate: UFix64,
    priceHistorySize: UInt8,
    priceHistoryInterval: UFix64,
    maxPriceHistoryAge: UFix64,
    minimumPriceHistory: UInt8,
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
            baseTolerance: baseTolerance,
            driftExpansionRate: driftExpansionRate,
            priceHistorySize: priceHistorySize,
            priceHistoryInterval: priceHistoryInterval,
            maxPriceHistoryAge: maxPriceHistoryAge,
            minimumPriceHistory: minimumPriceHistory,
            unitOfAccount: unitOfAccount
        )
    }
}