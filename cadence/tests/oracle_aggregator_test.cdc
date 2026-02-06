import Test
import BlockchainHelpers

import "FlowOracleAggregatorV1"
import "DeFiActions"
import "FlowToken"
import "test_helpers.cdc"

access(all) var snapshot: UInt64 = 0

access(all) fun setup() {
    deployContracts()
    var err = Test.deployContract(
        name: "FlowOracleAggregatorV1",
        path: "../contracts/FlowOracleAggregatorV1.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())

    snapshot = getCurrentBlockHeight()
    Test.commitBlock()
}

access(all) fun beforeEach() {
    Test.reset(to: snapshot)
}

access(all) fun test_create_aggregator() {
    let aggregator = FlowOracleAggregatorV1.createPriceOracleAggregator(
        uniqueID: DeFiActions.createUniqueIdentifier(),
        unitOfAccount: Type<@FlowToken.Vault>(),
        maxSpread: 0.05
    )
}

access(all) fun test_create_aggregator() {
    let aggregator = FlowOracleAggregatorV1.createPriceOracleAggregator(
        uniqueID: DeFiActions.createUniqueIdentifier(),
        unitOfAccount: Type<@FlowToken.Vault>(),
        maxSpread: 0.05
    )
}