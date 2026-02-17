import "DeFiActions"
import "FlowOracleAggregatorv1"
import "FlowToken"
import "MultiMockOracle"
import "MOET"

transaction(
    oracleCount: Int,
    maxSpread: UFix64,
    maxGradient: UFix64,
    priceHistorySize: Int,
    priceHistoryInterval: UFix64,
    unitOfAccount: Type
) {
    let oracles: [{DeFiActions.PriceOracle}]

    prepare() {
        self.oracles = []
        var i = 0
        while i < oracleCount {
            self.oracles.append(MultiMockOracle.createPriceOracle(unitOfAccountType: Type<@MOET.Vault>()))
            i = i + 1
        }
    }

    execute {
        let uuid = FlowOracleAggregatorv1.createPriceOracleAggregatorStorage(
            oracles: self.oracles,
            maxSpread: maxSpread,
            maxGradient: maxGradient,
            priceHistorySize: priceHistorySize,
            priceHistoryInterval: priceHistoryInterval,
            unitOfAccount: unitOfAccount
        )
    }
}